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

#import <Carrot/Carrot.h>
#import "Carrot+Internal.h"
#import "CarrotRequestThread.h"
#import "CarrotCachedRequest.h"
#import "AmazonSDKUtil.h"

#include <CommonCrypto/CommonHMAC.h>

@interface CarrotRequestThread ()

@property (strong, nonatomic) NSMutableArray* internalRequestQueue;
@property (weak, nonatomic, readwrite) NSArray* requestQueue;
@property (nonatomic, readwrite) sqlite3* sqliteDb;
@property (assign, nonatomic) Carrot* carrot;
@property (nonatomic) BOOL keepThreadRunning;
@property (strong, nonatomic) NSCondition* requestQueuePause;

@end

NSString* URLEscapedString(NSString* inString)
{
   return (NSString*)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)inString, NULL, (CFStringRef)@"!*'();:@&=+$,/?%#[]", kCFStringEncodingUTF8));
}

@implementation CarrotRequestThread

- (id)initWithCarrot:(Carrot*)carrot
{
   self = [super init];
   if(self)
   {
      self.internalRequestQueue = [[NSMutableArray alloc] init];
      self.requestQueue = self.internalRequestQueue;
      self.carrot = carrot;
      self.maxRetryCount = 0; // Infinite retries by default
      self.requestQueuePause = [[NSCondition alloc] init];
      _isRunning = NO;

      // Init sqlite
      int sql3Err = sqlite3_open([[carrot.dataPath stringByAppendingPathComponent:@"RequestQueue.db"] UTF8String], &_sqliteDb);
      if(sql3Err != SQLITE_OK)
      {
         NSLog(@"Error creating Carrot data store at: %@", carrot.dataPath);
         return nil;
      }

      // Create cache if needed
      BOOL cacheSuccess = YES;
      sqlite3_stmt* sqlStatement;
      if(sqlite3_prepare_v2(self.sqliteDb, [CarrotCachedRequest cacheCreateSQLStatement],
                            -1, &sqlStatement, NULL) == SQLITE_OK)
      {
         if(sqlite3_step(sqlStatement) != SQLITE_DONE)
         {
            NSLog(@"Failed to create Carrot cache. Error: %s'", sqlite3_errmsg(self.sqliteDb));
            cacheSuccess = NO;
         }
      }
      else
      {
         NSLog(@"Failed to create Carrot cache statement. Error: '%s'", sqlite3_errmsg(self.sqliteDb));
         cacheSuccess = NO;
      }
      sqlite3_finalize(sqlStatement);

      if(!cacheSuccess)
      {
         return nil;
      }
   }
   return self;
}

- (void)dealloc
{
   self.internalRequestQueue = nil;

   sqlite3_close(_sqliteDb);
   _sqliteDb = nil;
}

- (void)start
{
   if(!self.isRunning)
   {
      self.keepThreadRunning = YES;
      [NSThread detachNewThreadSelector:@selector(requestQueueProc:) toTarget:self withObject:nil];
   }
}

- (void)stop
{
   if(self.isRunning)
   {
      // Signal thread to start up if it is waiting
      [self.requestQueuePause lock];
      self.keepThreadRunning = NO;
      [self.requestQueuePause signal];
      [self.requestQueuePause unlock];
   }
}

- (BOOL)addRequestForEndpoint:(NSString*)endpoint usingMethod:(NSString*)method withPayload:(NSDictionary*)payload
{
   return [self addRequestForEndpoint:endpoint usingMethod:method withPayload:payload callback:nil atFront:NO];
}

- (BOOL)addRequestForEndpoint:(NSString*)endpoint usingMethod:(NSString*)method withPayload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback
{
      return [self addRequestForEndpoint:endpoint usingMethod:method withPayload:payload callback:callback atFront:NO];
}

- (BOOL)addRequestForEndpoint:(NSString*)endpoint usingMethod:(NSString*)method withPayload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback atFront:(BOOL)atFront
{
   BOOL ret = YES;
   if(method == CarrotRequestTypeGET)
   {
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
         @synchronized(self.internalRequestQueue)
         {
            if(atFront)
            {
               [self.internalRequestQueue insertObject:[CarrotRequest requestForEndpoint:endpoint
                                                                          usingMethod:method
                                                                          withPayload:payload
                                                                             callback:callback]
                                               atIndex:0];
            }
            else
            {
               [self.internalRequestQueue addObject:[CarrotRequest requestForEndpoint:endpoint
                                                                          usingMethod:method
                                                                          withPayload:payload
                                                                             callback:callback]];
            }
         }
      });
   }
   else
   {
      CarrotCachedRequest* cachedRequest =
      [CarrotCachedRequest requestForEndpoint:endpoint
                                  withPayload:payload
                                      inCache:self.sqliteDb
                        synchronizingOnObject:self.requestQueue];

      if(cachedRequest)
      {
         dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @synchronized(self.requestQueue)
            {
               if(atFront)
               {
                  [self.internalRequestQueue insertObject:cachedRequest atIndex:0];
               }
               else
               {
                  [self.internalRequestQueue addObject:cachedRequest];
               }
            }
         });
      }

      ret = (cachedRequest != nil);
   }

   // Signal thread to start up if it is waiting
   [self.requestQueuePause lock];
   [self.requestQueuePause signal];
   [self.requestQueuePause unlock];

   return ret;
}

- (BOOL)loadQueueFromCache
{
   BOOL ret = NO;
   @synchronized(self.requestQueue)
   {
      NSArray* cachedRequests = [CarrotCachedRequest requestsInCache:self.sqliteDb];
      [self.internalRequestQueue addObjectsFromArray:cachedRequests];
   }
   return ret;
}

- (NSString*)signedPostBody:(CarrotRequest*)request
{
   NSString* host = self.carrot.hostname;
   NSString* path = request.endpoint;
   if(path == nil || path.length < 1) path = @"/";

   // Build query dict
   NSDictionary* commonQueryDict = @{
      @"api_key" : self.carrot.udid,
      @"game_id" : self.carrot.appId
   };

   NSMutableDictionary* queryParamDict = [NSMutableDictionary dictionaryWithDictionary:request.payload];
   [queryParamDict addEntriesFromDictionary:commonQueryDict];

   // Build query string to sign
   NSArray* queryKeysSorted = [[queryParamDict allKeys]
                               sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
   NSMutableString* sortedQueryString = [[NSMutableString alloc] init];
   for(int i = 0; i < queryKeysSorted.count; i++)
   {
      NSString* key = [queryKeysSorted objectAtIndex:i];
      id value = [queryParamDict objectForKey:key];
      NSString* valueString = value;
      if([value isKindOfClass:[NSDictionary class]] ||
         [value isKindOfClass:[NSArray class]])
      {
         NSError* error = nil;

         NSData* jsonData = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
         if(error)
         {
            NSLog(@"Error converting %@ to JSON: %@", value, error);
            valueString = [value description];
         }
         else
         {
            valueString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
         }
      }
      [sortedQueryString appendFormat:@"%@=%@%s", key, valueString,
       (i + 1 < queryKeysSorted.count ? "&" : "")];
   }

   NSString* stringToSign = [NSString stringWithFormat:@"%@\n%@\n%@\n%@", request.method, host, path,
                             sortedQueryString];

   NSData* dataToSign = [stringToSign dataUsingEncoding:NSUTF8StringEncoding];
   uint8_t digestBytes[CC_SHA256_DIGEST_LENGTH];
   CCHmac(kCCHmacAlgSHA256, [self.carrot.appSecret UTF8String], self.carrot.appSecret.length,
          [dataToSign bytes], [dataToSign length], &digestBytes);

   NSData* digestData = [NSData dataWithBytes:digestBytes length:CC_SHA256_DIGEST_LENGTH];
   NSString* sigString = URLEscapedString([NSDataWithBase64 base64EncodedStringFromData:digestData]);

   // Build URL escaped query string
   sortedQueryString = [[NSMutableString alloc] init];
   for(int i = 0; i < queryKeysSorted.count; i++)
   {
      NSString* key = [queryKeysSorted objectAtIndex:i];
      id value = [queryParamDict objectForKey:key];
      NSString* valueString = value;
      if([value isKindOfClass:[NSDictionary class]] ||
         [value isKindOfClass:[NSArray class]])
      {
         NSError* error = nil;
         
         NSData* jsonData = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
         if(error)
         {
            NSLog(@"Error converting %@ to JSON: %@", value, error);
            valueString = [value description];
         }
         else
         {
            valueString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
         }
      }
      [sortedQueryString appendFormat:@"%@=%@&", key,
       ([value isKindOfClass:[NSNumber class]]) ? value : URLEscapedString(valueString)];
   }
   [sortedQueryString appendFormat:@"sig=%@", sigString];

   return sortedQueryString;
}

- (void)requestQueueProc:(id)context
{
   _isRunning = YES;
   @autoreleasepool
   {
      while(self.keepThreadRunning)
      {
         if(self.carrot.appSecret)
         {
            CarrotCachedRequest* request = nil;

            @synchronized(self.requestQueue)
            {
               request = (self.requestQueue.count > 0 ?
                          [self.requestQueue objectAtIndex:0] : nil);
            }

            if(request)
            {
               NSString* postBody = [self signedPostBody:request];

               NSMutableURLRequest* preppedRequest = nil;
               if(request.method == CarrotRequestTypePOST)
               {
                  NSData* postData = [postBody dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
                  preppedRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", self.carrot.hostname, request.endpoint]]];

                  [preppedRequest setHTTPBody:postData];
                  [preppedRequest setValue:[NSString stringWithFormat:@"%d", [postData length]]
                        forHTTPHeaderField:@"Content-Length"];
                  [preppedRequest setValue:@"application/x-www-form-urlencoded"
                        forHTTPHeaderField:@"Content-Type"];
               }
               else
               {
                  preppedRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@?%@", self.carrot.hostname, request.endpoint, postBody]]];
               }
               [preppedRequest setHTTPMethod:request.method];

               // Allocate response
               NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc]
                                               initWithURL:preppedRequest.URL
                                                  MIMEType:@"application/x-www-form-urlencoded"
                                     expectedContentLength:-1
                                          textEncodingName:nil];
               NSError* error = nil;

               // Issue request
               NSData* data = [NSURLConnection sendSynchronousRequest:preppedRequest
                                                    returningResponse:&response
                                                                error:&error];

               // Handle response
               if(error)
               {
                  NSLog(@"Error submitting Carrot request: %@", error);
               }
               else if(request.callback)
               {
                  request.callback(response, data, self);
               }

               @synchronized(self.requestQueue)
               {
                  [self.internalRequestQueue removeObjectAtIndex:0];
               }
            }
            else
            {
               [self.requestQueuePause lock];

               // Populate cache
               [self loadQueueFromCache];

               // If queue is still empty, wait until it's not empty.
               while([self.internalRequestQueue count] < 1 && self.keepThreadRunning) {
                  [self.requestQueuePause wait];
               }
               [self.requestQueuePause unlock];
            }
         }
      }
   }
   _isRunning = NO;
}

@end
