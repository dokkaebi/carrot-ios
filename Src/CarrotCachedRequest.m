/* Carrot -- Copyright (C) 2012 GoCarrot Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Carrot+Internal.h"
#import "CarrotCachedRequest.h"
#import "CarrotRequestThread.h"

#define kCarrotDefaultHostname @"gocarrot.com"
#define kCarrotDefaultHostUrlScheme @"https"

// Cache schema version
#define kCacheSchemaCreateSQL "CREATE TABLE IF NOT EXISTS cache_schema(schema_version INTEGER)"
#define kCacheSchemaReadSQL "SELECT MAX(schema_version) FROM cache_schema"
#define kCacheSchemaInsertSQL "INSERT INTO cache_schema(schema_version) VALUES (%d)"

// v0
#define kCacheCreateV0SQL "CREATE TABLE IF NOT EXISTS cache(request_endpoint TEXT, request_payload TEXT, request_id TEXT, request_date REAL, retry_count INTEGER)"

// v0->v1
#define kCacheAlterV0toV1SQL "ALTER TABLE cache ADD COLUMN request_servicetype INTEGER"
#define kCacheUpdateV0toV1SQL "UPDATE cache SET request_servicetype=%d"

#define kCacheReadSQL "SELECT rowid, request_servicetype, request_endpoint, request_payload, request_id, request_date, retry_count FROM cache WHERE request_servicetype<=%d ORDER BY retry_count"
#define kCacheInsertSQL "INSERT INTO cache (request_servicetype, request_endpoint, request_payload, request_id, request_date, retry_count) VALUES (%d, %Q, %Q, %Q, %f, %d)"
#define kCacheUpdateSQL "UPDATE cache SET retry_count=%d WHERE rowid=%lld"
#define kCacheDeleteSQL "DELETE FROM cache WHERE rowid=%lld"

@interface CarrotCachedRequest ()

@property (strong, nonatomic, readwrite) NSString* requestId;
@property (strong, nonatomic, readwrite) NSDate* dateIssued;
@property (nonatomic, readwrite) NSUInteger retryCount;

@property (nonatomic) sqlite3_uint64 cacheId;

@end

static BOOL carrotcache_begin(sqlite3* cache)
{
   if(sqlite3_exec(cache, "BEGIN TRANSACTION", 0, 0, 0) != SQLITE_OK)
   {
      NSLog(@"Failed to begin Carrot cache transaction. Error: %s'", sqlite3_errmsg(cache));
      return NO;
   }
   return YES;
}

static BOOL carrotcache_rollback(sqlite3* cache)
{
   if(sqlite3_exec(cache, "ROLLBACK", 0, 0, 0) != SQLITE_OK)
   {
      NSLog(@"Failed to rollback Carrot cache transaction. Error: %s'", sqlite3_errmsg(cache));
      return NO;
   }
   return YES;
}

static BOOL carrotcache_commit(sqlite3* cache)
{
   if(sqlite3_exec(cache, "COMMIT", 0, 0, 0) != SQLITE_OK)
   {
      NSLog(@"Failed to commit Carrot cache transaction. Error: %s'", sqlite3_errmsg(cache));
      return NO;
   }
   return YES;
}

#define CARROTCACHE_ROLLBACK_FAIL(test, cache) if(!test){ carrotcache_rollback(cache); return NO; }

@implementation CarrotCachedRequest

+ (BOOL)prepareCache:(sqlite3*)cache
{
   BOOL ret = YES;

   sqlite3_stmt* sqlStatement;

   // Create schema version table
   if(sqlite3_prepare_v2(cache, kCacheSchemaCreateSQL, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      if(sqlite3_step(sqlStatement) != SQLITE_DONE)
      {
         NSLog(@"Failed to create Carrot cache schema. Error: %s'", sqlite3_errmsg(cache));
         ret = NO;
      }
   }
   else
   {
      NSLog(@"Failed to create Carrot cache schema statement. Error: '%s'", sqlite3_errmsg(cache));
      ret = NO;
   }
   sqlite3_finalize(sqlStatement);

   if(!ret) return ret;

   // Read cache schema version
   NSUInteger cacheSchemaVersion = 0;
   if(sqlite3_prepare_v2(cache, kCacheSchemaReadSQL, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      while(sqlite3_step(sqlStatement) == SQLITE_ROW)
      {
         cacheSchemaVersion = sqlite3_column_int(sqlStatement, 0);
      }
   }
   sqlite3_finalize(sqlStatement);

   // Create v0 cache if needed
   if(sqlite3_prepare_v2(cache, kCacheCreateV0SQL, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      if(sqlite3_step(sqlStatement) != SQLITE_DONE)
      {
         NSLog(@"Failed to create Carrot cache. Error: %s'", sqlite3_errmsg(cache));
         ret = NO;
      }
   }
   else
   {
      NSLog(@"Failed to create Carrot cache statement. Error: '%s'", sqlite3_errmsg(cache));
      ret = NO;
   }
   sqlite3_finalize(sqlStatement);

   if(!ret) return ret;

   // Perform migrations
   if(cacheSchemaVersion == 0)
   {
      // Begin transaction
      if(!carrotcache_begin(cache)) return NO;

      // Alter cache table
      if(sqlite3_prepare_v2(cache, kCacheAlterV0toV1SQL, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to migrate Carrot cache. Error: %s'", sqlite3_errmsg(cache));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache migration statement. Error: '%s'", sqlite3_errmsg(cache));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);

      CARROTCACHE_ROLLBACK_FAIL(ret, cache);

      // Update schema version
      char* sqlString = sqlite3_mprintf(kCacheSchemaInsertSQL, 1);
      if(sqlite3_prepare_v2(cache, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to update Carrot cache schema version. Error: %s'", sqlite3_errmsg(cache));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache schema version update statement. Error: '%s'", sqlite3_errmsg(cache));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);
      sqlite3_free(sqlString);

      CARROTCACHE_ROLLBACK_FAIL(ret, cache);

      // Update cache contents to v1 (all cached requests prior to v1 were CarrotRequestServicePost)
      sqlString = sqlite3_mprintf(kCacheUpdateV0toV1SQL, CarrotRequestServicePost);
      if(sqlite3_prepare_v2(cache, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to update Carrot cache. Error: %s'", sqlite3_errmsg(cache));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache update statement. Error: '%s'", sqlite3_errmsg(cache));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);
      sqlite3_free(sqlString);

      // Commit transaction
      CARROTCACHE_ROLLBACK_FAIL(ret && carrotcache_commit(cache), cache);
   }

   return ret;
}

+ (id)requestForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint withPayload:(NSDictionary*)payload inCache:(sqlite3*)cache synchronizingOnObject:(id)synchObject
{
   sqlite_uint64 cacheId = 0;
   NSUInteger retryCount = 0;
   BOOL successful = NO;
   CarrotCachedRequest* ret = nil;
   NSDate* dateIssued = [NSDate date];

   NSError* error = nil;
   NSString* payloadJSON = nil;
   NSData* payloadJSONData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
   if(error)
   {
      NSLog(@"Error converting payload to JSON: %@", error);
      return nil;
   }
   else
   {
      payloadJSON = [[NSString alloc] initWithData:payloadJSONData encoding:NSUTF8StringEncoding];
   }

   CFUUIDRef theUUID = CFUUIDCreate(NULL);
   CFStringRef uuidString = CFUUIDCreateString(NULL, theUUID);
   CFRelease(theUUID);
   NSString* requestId = (__bridge NSString*)uuidString;

   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheInsertSQL,
                                     serviceType,
                                     [endpoint UTF8String],
                                     [payloadJSON UTF8String],
                                     [requestId UTF8String],
                                     [dateIssued timeIntervalSince1970], retryCount);
   @synchronized(synchObject)
   {
      if(sqlite3_prepare_v2(cache, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) == SQLITE_DONE)
         {
            cacheId = sqlite3_last_insert_rowid(cache);
            successful = YES;
         }
         else
         {
            NSLog(@"Failed to write request to Carrot cache. Error: '%s'", sqlite3_errmsg(cache));
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache statement for request. Error: '%s'", sqlite3_errmsg(cache));
      }
      sqlite3_finalize(sqlStatement);
   }
   sqlite3_free(sqlString);

   if(successful)
   {
      ret = [[CarrotCachedRequest alloc] initForService:serviceType
                                             atEndpoint:endpoint
                                                payload:payload
                                              requestId:requestId
                                                cacheId:cacheId
                                             dateIssued:dateIssued
                                             retryCount:retryCount];
   }

   // Clean up
   CFRelease(uuidString);

   return ret;
}

+ (NSArray*)requestsInCache:(sqlite3*)cache forAuthStatus:(CarrotAuthenticationStatus)authStatus
{
   NSMutableArray* cacheArray = [[NSMutableArray alloc] init];

   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheReadSQL, authStatus);
   if(sqlite3_prepare_v2(cache, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      while(sqlite3_step(sqlStatement) == SQLITE_ROW)
      {
         sqlite_uint64 cacheId = sqlite3_column_int64(sqlStatement, 0);
         NSInteger serviceType = sqlite3_column_int(sqlStatement, 1);
         NSString* requestEndpoint = [NSString stringWithUTF8String:(const char*)sqlite3_column_text(sqlStatement, 2)];
         NSString* requestPayloadJSON = (sqlite3_column_text(sqlStatement, 3) == NULL ? nil : [NSString stringWithUTF8String:(const char*)sqlite3_column_text(sqlStatement, 3)]);
         NSString* requestId = [NSString stringWithUTF8String:(const char*)sqlite3_column_text(sqlStatement, 4)];
         NSDate* requestDate = [NSDate dateWithTimeIntervalSince1970:sqlite3_column_double(sqlStatement, 5)];
         NSUInteger retryCount = sqlite3_column_int(sqlStatement, 6);

         NSError* error = nil;
         NSDictionary* requestPayload = [NSJSONSerialization JSONObjectWithData:[requestPayloadJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];

         // Add to array
         if(error)
         {
            NSLog(@"Error converting JSON payload to NSDictionary: %@", error);
         }
         else
         {
            CarrotCachedRequest* request = [[CarrotCachedRequest alloc]
                                            initForService:serviceType
                                                atEndpoint:requestEndpoint
                                                   payload:requestPayload
                                                 requestId:requestId
                                                   cacheId:cacheId
                                                dateIssued:requestDate
                                                retryCount:retryCount];
            [cacheArray addObject:request];
         }
      }
   }
   else
   {
      NSLog(@"Failed to load Carrot request cache.");
   }
   sqlite3_finalize(sqlStatement);
   sqlite3_free(sqlString);

   return cacheArray;
}

- (id)initForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint payload:(NSDictionary*)payload requestId:(NSString*)requestId cacheId:(sqlite_uint64)cacheId dateIssued:(NSDate*)dateIssued retryCount:(NSUInteger)retryCount
{
   NSMutableDictionary* finalPayload = [payload mutableCopy];
   [finalPayload setObject:requestId forKey:@"request_id"];
   [finalPayload setObject:[NSNumber numberWithLongLong:(uint64_t)[dateIssued timeIntervalSince1970]] forKey:@"request_date"];

   self = [super initForService:serviceType atEndpoint:endpoint usingMethod:CarrotRequestTypePOST payload:finalPayload callback:^(NSHTTPURLResponse* response, NSData* data, CarrotRequestThread* requestThread) {
      [self requestCallbackStatus:response data:data thread:requestThread];
   }];

   if(self)
   {
      self.requestId = requestId;
      self.cacheId = cacheId;
      self.dateIssued = dateIssued;
      self.retryCount = retryCount;
   }
   return self;
}

- (BOOL)removeFromCache:(sqlite3*)cache
{
   BOOL ret = YES;
   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheDeleteSQL, self.cacheId);
   if(sqlite3_prepare_v2(cache, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      if(sqlite3_step(sqlStatement) != SQLITE_DONE)
      {
         NSLog(@"Failed to delete Carrot request id %lld from cache. Error: '%s'",
               self.cacheId, sqlite3_errmsg(cache));
         ret = NO;
      }
   }
   else
   {
      NSLog(@"Failed to create cache delete statement for Carrot request id %lld. "
            "Error: '%s'", self.cacheId, sqlite3_errmsg(cache));
      ret = NO;
   }
   sqlite3_finalize(sqlStatement);
   sqlite3_free(sqlString);

   return ret;
}

- (BOOL)addRetryInCache:(sqlite3*)cache
{
   BOOL ret = YES;
   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheUpdateSQL, self.retryCount + 1, self.cacheId);
   if(sqlite3_prepare_v2(cache, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      if(sqlite3_step(sqlStatement) != SQLITE_DONE)
      {
         NSLog(@"Failed to update Carrot request id %lld in cache. Error: '%s'",
               self.cacheId, sqlite3_errmsg(cache));
         ret = NO;
      }
   }
   else
   {
      NSLog(@"Failed to create cache update statement for Carrot request id %lld. "
            "Error: '%s'", self.cacheId, sqlite3_errmsg(cache));
      ret = NO;
   }
   sqlite3_finalize(sqlStatement);
   sqlite3_free(sqlString);

   return ret;
}

- (NSString*)description
{
   return [NSString stringWithFormat:@"Carrot Request: {\n\t'request_servicetype':'%d'\n\t'request_endpoint':'%@',\n\t'request_payload':'%@',\n\t'request_id':'%@',\n\t'request_date':'%@',\n\t'retry_count':'%d'\n}", self.serviceType, self.endpoint, self.payload, self.requestId, self.dateIssued, self.retryCount];
}

- (void)requestCallbackStatus:(NSHTTPURLResponse*)response data:(NSData*)data thread:(CarrotRequestThread*)requestThread
{
   NSError* error = nil;
   NSDictionary* jsonReply = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
   int httpCode = response != nil ? response.statusCode : 401;
   if(httpCode == 404)
   {
      NSLog(@"Carrot resource not found, removing request from cache.");
      @synchronized(requestThread.requestQueue)
      {
         [self removeFromCache:requestThread.sqliteDb];
      }
   }
   else if([[Carrot sharedInstance] updateAuthenticationStatus:httpCode])
   {
      if([Carrot sharedInstance].authenticationStatus == CarrotAuthenticationStatusReady)
      {
         @synchronized(requestThread.requestQueue)
         {
            [self removeFromCache:requestThread.sqliteDb];
         }
      }
      else
      {
         @synchronized(requestThread.requestQueue)
         {
            [self addRetryInCache:requestThread.sqliteDb];
         }
      }
   }
   else
   {
      NSLog(@"Unknown error (%d) submitting Carrot request: %@\nJSON:%@",
            response.statusCode, self, jsonReply);
      if(requestThread.maxRetryCount > 0 && self.retryCount > requestThread.maxRetryCount)
      {
         // Remove request, never retry
         NSLog(@"Removing request from Carrot cache, too many retries.");
         @synchronized(requestThread.requestQueue)
         {
            [self removeFromCache:requestThread.sqliteDb];
         }
      }
      else
      {
         @synchronized(requestThread.requestQueue)
         {
            [self addRetryInCache:requestThread.sqliteDb];
         }
      }
   }
}

@end
