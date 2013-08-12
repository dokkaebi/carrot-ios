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

#import <Carrot/Carrot.h>
#import "CarrotCache.h"
#import "CarrotCachedRequest.h"

// Cache schema version
#define kCacheSchemaCreateSQL "CREATE TABLE IF NOT EXISTS cache_schema(schema_version INTEGER)"
#define kCacheSchemaReadSQL "SELECT MAX(schema_version) FROM cache_schema"
#define kCacheSchemaInsertSQL "INSERT INTO cache_schema(schema_version) VALUES (%d)"

// v0
#define kCacheCreateV0SQL "CREATE TABLE IF NOT EXISTS cache(request_endpoint TEXT, request_payload TEXT, request_id TEXT, request_date REAL, retry_count INTEGER)"

// v0->v1
#define kCacheAlterV0toV1SQL "ALTER TABLE cache ADD COLUMN request_servicetype INTEGER"
#define kCacheUpdateV0toV1SQL "UPDATE cache SET request_servicetype=%d"

#define kCacheReadSQL "SELECT rowid, request_servicetype, request_endpoint, request_payload, request_id, request_date, retry_count FROM cache WHERE request_servicetype<=%d ORDER BY retry_count LIMIT 10"
#define kCacheInsertSQL "INSERT INTO cache (request_servicetype, request_endpoint, request_payload, request_id, request_date, retry_count) VALUES (%d, %Q, %Q, %Q, %f, %d)"
#define kCacheUpdateSQL "UPDATE cache SET retry_count=%d WHERE rowid=%lld"
#define kCacheDeleteSQL "DELETE FROM cache WHERE rowid=%lld"

// Install tracking
#define kInstallTableCreateSQL "CREATE TABLE IF NOT EXISTS install_tracking(install_date REAL, metric_sent INTEGER)"
#define kInstallTableReadSQL "SELECT MAX(install_date), metric_sent FROM install_tracking"
#define kInstallTableUpdateSQL "INSERT INTO install_tracking (install_date, metric_sent) VALUES (%f, 0)"
#define kInstallTableMetricSentSQL "UPDATE install_tracking SET metric_sent=1"

@interface CarrotCache ()

@property (strong, nonatomic, readwrite) NSDate* installDate;
@property (nonatomic, readwrite) sqlite3* sqliteDb;
@property (nonatomic, readwrite) BOOL installMetricSent;

@end

static BOOL carrotcache_begin(sqlite3* cache);
static BOOL carrotcache_rollback(sqlite3* cache);
static BOOL carrotcache_commit(sqlite3* cache);
#define CARROTCACHE_ROLLBACK_FAIL(test, cache) if(!(test)){ carrotcache_rollback(cache); return NO; }

@implementation CarrotCache

+ (id)cacheWithPath:(NSString*)path
{
   return [[CarrotCache alloc] initWithPath:path];
}

- (id)initWithPath:path
{
   sqlite3* sqliteDb;
   int sql3Err = sqlite3_open([[path stringByAppendingPathComponent:@"RequestQueue.db"] UTF8String],
                              &sqliteDb);
   if(sql3Err != SQLITE_OK)
   {
      NSLog(@"Error creating Carrot data store at: %@", path);
      return nil;
   }

   self = [super init];
   if(self)
   {
      self.sqliteDb = sqliteDb;
      [self prepareCache];
   }
   return self;
}

- (void)dealloc
{
   sqlite3_close(_sqliteDb);
   _sqliteDb = nil;
}

- (void)markAppInstalled
{
   sqlite3_exec(self.sqliteDb, kInstallTableMetricSentSQL, 0, 0, 0);
   self.installMetricSent = YES;
}

- (sqlite_uint64)cacheRequest:(CarrotCachedRequest*)request
{
   sqlite_uint64 cacheId = 0;
   NSError* error = nil;
   NSString* payloadJSON = nil;
   NSData* payloadJSONData = [NSJSONSerialization dataWithJSONObject:[CarrotRequest finalPayloadForPayload:request.payload] options:0 error:&error];
   if(error)
   {
      NSLog(@"Error converting payload to JSON: %@", error);
      return 0;
   }
   else
   {
      payloadJSON = [[NSString alloc] initWithData:payloadJSONData encoding:NSUTF8StringEncoding];
   }

   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheInsertSQL,
                                     request.serviceType,
                                     [request.endpoint UTF8String],
                                     [payloadJSON UTF8String],
                                     [request.requestId UTF8String],
                                     [request.dateIssued timeIntervalSince1970],
                                     request.retryCount);
   @synchronized(self)
   {
      if(sqlite3_prepare_v2(self.sqliteDb, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) == SQLITE_DONE)
         {
            cacheId = sqlite3_last_insert_rowid(self.sqliteDb);
         }
         else
         {
            NSLog(@"Failed to write request to Carrot cache. Error: '%s'",
                  sqlite3_errmsg(self.sqliteDb));
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache statement for request. Error: '%s'",
               sqlite3_errmsg(self.sqliteDb));
      }
      sqlite3_finalize(sqlStatement);
   }
   sqlite3_free(sqlString);
   return cacheId;
}


- (BOOL)removeRequestFromCache:(CarrotCachedRequest*)request
{
   BOOL ret = YES;
   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheDeleteSQL, request.cacheId);

   @synchronized(self)
   {
      if(sqlite3_prepare_v2(self.sqliteDb, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to delete Carrot request id %lld from cache. Error: '%s'",
                  request.cacheId, sqlite3_errmsg(self.sqliteDb));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create cache delete statement for Carrot request id %lld. "
               "Error: '%s'", request.cacheId, sqlite3_errmsg(self.sqliteDb));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);
      sqlite3_free(sqlString);
   }

   return ret;
}

- (BOOL)addRetryInCacheForRequest:(CarrotCachedRequest*)request
{
   BOOL ret = YES;
   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheUpdateSQL, request.retryCount + 1, request.cacheId);

   @synchronized(self)
   {
      if(sqlite3_prepare_v2(self.sqliteDb, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to update Carrot request id %lld in cache. Error: '%s'",
                  request.cacheId, sqlite3_errmsg(self.sqliteDb));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create cache update statement for Carrot request id %lld. "
               "Error: '%s'", request.cacheId, sqlite3_errmsg(self.sqliteDb));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);
   }
   sqlite3_free(sqlString);

   return ret;
}

- (NSArray*)cachedRequestsForAuthStatus:(CarrotAuthenticationStatus)authStatus
{
   NSMutableArray* cacheArray = [[NSMutableArray alloc] init];

   sqlite3_stmt* sqlStatement;
   char* sqlString = sqlite3_mprintf(kCacheReadSQL, authStatus);
   @synchronized(self)
   {
      if(sqlite3_prepare_v2(self.sqliteDb, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
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
                                               dateIssued:requestDate
                                               cacheId:cacheId
                                               retryCount:retryCount];
               if(request)
               {
                  [cacheArray addObject:request];
               }
            }
         }
      }
      else
      {
         NSLog(@"Failed to load Carrot request cache.");
      }
      sqlite3_finalize(sqlStatement);
   }
   sqlite3_free(sqlString);

   return cacheArray;
}

- (BOOL)prepareCache
{
   BOOL ret = YES;

   sqlite3_stmt* sqlStatement;

   // Create schema version table
   if(sqlite3_prepare_v2(self.sqliteDb, kCacheSchemaCreateSQL, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      if(sqlite3_step(sqlStatement) != SQLITE_DONE)
      {
         NSLog(@"Failed to create Carrot cache schema. Error: %s'", sqlite3_errmsg(self.sqliteDb));
         ret = NO;
      }
   }
   else
   {
      NSLog(@"Failed to create Carrot cache schema statement. Error: '%s'", sqlite3_errmsg(self.sqliteDb));
      ret = NO;
   }
   sqlite3_finalize(sqlStatement);

   if(!ret) return ret;

   // Read cache schema version
   NSUInteger cacheSchemaVersion = 0;
   if(sqlite3_prepare_v2(self.sqliteDb, kCacheSchemaReadSQL, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      while(sqlite3_step(sqlStatement) == SQLITE_ROW)
      {
         cacheSchemaVersion = sqlite3_column_int(sqlStatement, 0);
      }
   }
   sqlite3_finalize(sqlStatement);

   // Create v0 cache if needed
   if(sqlite3_prepare_v2(self.sqliteDb, kCacheCreateV0SQL, -1, &sqlStatement, NULL) == SQLITE_OK)
   {
      if(sqlite3_step(sqlStatement) != SQLITE_DONE)
      {
         NSLog(@"Failed to create Carrot cache. Error: %s'", sqlite3_errmsg(self.sqliteDb));
         ret = NO;
      }
   }
   else
   {
      NSLog(@"Failed to create Carrot cache statement. Error: '%s'", sqlite3_errmsg(self.sqliteDb));
      ret = NO;
   }
   sqlite3_finalize(sqlStatement);

   if(!ret) return ret;

   // Perform migrations
   if(cacheSchemaVersion == 0)
   {
      // Begin transaction
      if(!carrotcache_begin(self.sqliteDb)) return NO;

      // Alter cache table
      if(sqlite3_prepare_v2(self.sqliteDb, kCacheAlterV0toV1SQL, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to migrate Carrot cache. Error: %s'", sqlite3_errmsg(self.sqliteDb));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache migration statement. Error: '%s'", sqlite3_errmsg(self.sqliteDb));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);

      CARROTCACHE_ROLLBACK_FAIL(ret, self.sqliteDb);

      // Update schema version
      char* sqlString = sqlite3_mprintf(kCacheSchemaInsertSQL, 1);
      if(sqlite3_prepare_v2(self.sqliteDb, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to update Carrot cache schema version. Error: %s'", sqlite3_errmsg(self.sqliteDb));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache schema version update statement. Error: '%s'", sqlite3_errmsg(self.sqliteDb));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);
      sqlite3_free(sqlString);

      CARROTCACHE_ROLLBACK_FAIL(ret, self.sqliteDb);

      // Update cache contents to v1 (all cached requests prior to v1 were CarrotRequestServicePost)
      sqlString = sqlite3_mprintf(kCacheUpdateV0toV1SQL, CarrotRequestServicePost);
      if(sqlite3_prepare_v2(self.sqliteDb, sqlString, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to update Carrot cache. Error: %s'", sqlite3_errmsg(self.sqliteDb));
            ret = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache update statement. Error: '%s'", sqlite3_errmsg(self.sqliteDb));
         ret = NO;
      }
      sqlite3_finalize(sqlStatement);
      sqlite3_free(sqlString);

      // Commit transaction
      CARROTCACHE_ROLLBACK_FAIL(ret && carrotcache_commit(self.sqliteDb), self.sqliteDb);
   }

   if(sqlite3_exec(self.sqliteDb, kInstallTableCreateSQL, 0, 0, 0) == SQLITE_OK)
   {
      sqlite3_stmt* sqlStatement;
      double cachedInstallDate = 0.0;
      if(sqlite3_prepare_v2(self.sqliteDb, kInstallTableReadSQL, -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         while(sqlite3_step(sqlStatement) == SQLITE_ROW)
         {
            cachedInstallDate = sqlite3_column_double(sqlStatement, 0);
            self.installMetricSent = sqlite3_column_int(sqlStatement, 1);
         }
      }
      sqlite3_finalize(sqlStatement);

      if(cachedInstallDate > 0.0)
      {
         self.installDate = [NSDate dateWithTimeIntervalSince1970: cachedInstallDate];
      }
      else
      {
         self.installDate = [NSDate date];

         char* sqlString = sqlite3_mprintf(kInstallTableUpdateSQL,
                                           [self.installDate timeIntervalSince1970]);
         sqlite3_exec(self.sqliteDb, sqlString, 0, 0, 0);
         sqlite3_free(sqlString);
      }
   }

   return ret;
}

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
