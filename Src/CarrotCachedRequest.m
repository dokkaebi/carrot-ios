/* Carrot -- Copyright (C) 2012 Carrot Inc.
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

#import "CarrotCachedRequest.h"

#define kCacheCreateSQL "CREATE TABLE IF NOT EXISTS cache(request_endpoint TEXT, request_payload TEXT, request_id TEXT, request_date REAL, retry_count INTEGER)"
#define kCacheReadSQL "SELECT rowid, request_endpoint, request_payload, request_id, request_date, retry_count FROM cache ORDER BY retry_count"
#define kCacheInsertSQL "INSERT INTO cache (request_endpoint, request_payload, request_id, request_date, retry_count) VALUES (%Q, %Q, %Q, %f, %d)"
#define kCacheUpdateSQL "UPDATE cache SET retry_count=%d WHERE rowid=%lld"
#define kCacheDeleteSQL "DELETE FROM cache WHERE rowid=%lld"

@interface CarrotCachedRequest ()

@property (strong, nonatomic, readwrite) NSString* endpoint;
@property (strong, nonatomic, readwrite) NSDictionary* payload;
@property (strong, nonatomic, readwrite) NSString* requestId;
@property (strong, nonatomic, readwrite) NSDate* dateIssued;
@property (nonatomic, readwrite) NSUInteger retryCount;

@property (nonatomic) sqlite3_uint64 cacheId;

@end

@implementation CarrotCachedRequest

+ (const char*)cacheCreateSQLStatement
{
   return kCacheCreateSQL;
}

+ (id)requestForEndpoint:(NSString*)endpoint withPayload:(NSDictionary*)payload inCache:(sqlite3*)cache synchronizingOnObject:(id)synchObject
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
   char* sqlString = sqlite3_mprintf(kCacheInsertSQL, [endpoint UTF8String],
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
      ret = [[CarrotCachedRequest alloc] initWithEndpoint:endpoint
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

+ (NSArray*)requestsInCache:(sqlite3*)cache
{
   NSMutableArray* cacheArray = [[NSMutableArray alloc] init];

   sqlite3_stmt* sqlStatement;
   if(sqlite3_prepare_v2(cache, kCacheReadSQL, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      while(sqlite3_step(sqlStatement) == SQLITE_ROW)
      {
         sqlite_uint64 cacheId = sqlite3_column_int64(sqlStatement, 0);
         NSString* requestEndpoint = [NSString stringWithUTF8String:(const char*)sqlite3_column_text(sqlStatement, 1)];
         NSString* requestPayloadJSON = (sqlite3_column_text(sqlStatement, 2) == NULL ? nil : [NSString stringWithUTF8String:(const char*)sqlite3_column_text(sqlStatement, 2)]);
         NSString* requestId = [NSString stringWithUTF8String:(const char*)sqlite3_column_text(sqlStatement, 3)];
         NSDate* requestDate = [NSDate dateWithTimeIntervalSince1970:sqlite3_column_double(sqlStatement, 4)];
         NSUInteger retryCount = sqlite3_column_int(sqlStatement, 5);

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
                                             initWithEndpoint:requestEndpoint
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

   return cacheArray;
}

- (id)initWithEndpoint:(NSString*)endpoint payload:(NSDictionary*)payload requestId:(NSString*)requestId cacheId:(sqlite_uint64)cacheId dateIssued:(NSDate*)dateIssued retryCount:(NSUInteger)retryCount
{
   self = [super init];
   if(self)
   {
      self.endpoint = endpoint;
      self.payload = payload;
      self.requestId = requestId;
      self.cacheId = cacheId;
      self.dateIssued = dateIssued;
      self.retryCount = retryCount;
   }
   return self;
}

- (void)deinit
{
   self.endpoint = nil;
   self.payload = nil;
   self.requestId = nil;
   self.dateIssued = nil;
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
   return [NSString stringWithFormat:@"Carrot Request: {\n\t'request_endpoint':'%@',\n\t'request_payload':'%@',\n\t'request_id':'%@',\n\t'request_date':'%@',\n\t'retry_count':'%d'\n}", self.endpoint, self.payload, self.requestId, self.dateIssued, self.retryCount];
}

@end
