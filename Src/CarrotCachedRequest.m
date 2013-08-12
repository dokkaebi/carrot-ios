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

@interface CarrotCachedRequest ()

@property (strong, nonatomic, readwrite) NSString* requestId;
@property (strong, nonatomic, readwrite) NSDate* dateIssued;
@property (nonatomic, readwrite) NSUInteger retryCount;
@property (nonatomic, readwrite) sqlite3_uint64 cacheId;

@end

@implementation CarrotCachedRequest

+ (id)requestForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint withPayload:(NSDictionary*)payload inCache:(CarrotCache*)cache
{
   NSUInteger retryCount = 0;
   CarrotCachedRequest* ret = nil;
   NSDate* dateIssued = [NSDate date];

   CFUUIDRef theUUID = CFUUIDCreate(NULL);
   CFStringRef uuidString = CFUUIDCreateString(NULL, theUUID);
   CFRelease(theUUID);
   NSString* requestId = (__bridge NSString*)uuidString;

   ret = [[CarrotCachedRequest alloc] initForService:serviceType
                                          atEndpoint:endpoint
                                             payload:payload
                                           requestId:requestId
                                          dateIssued:dateIssued
                                             cacheId:0
                                          retryCount:retryCount];
   ret.cacheId = [cache cacheRequest:ret];

   // Clean up
   CFRelease(uuidString);

   return ret;
}

- (id)initForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint payload:(NSDictionary*)payload requestId:(NSString*)requestId dateIssued:(NSDate*)dateIssued cacheId:(sqlite3_uint64)cacheId retryCount:(NSUInteger)retryCount
{
   NSMutableDictionary* finalPayload = [payload mutableCopy];
   [finalPayload setObject:requestId forKey:@"request_id"];
   [finalPayload setObject:[NSNumber numberWithLongLong:(uint64_t)[dateIssued timeIntervalSince1970]] forKey:@"request_date"];

   self = [super initForService:serviceType atEndpoint:endpoint usingMethod:CarrotRequestTypePOST payload:finalPayload callback:^(CarrotRequest* request, NSHTTPURLResponse* response, NSData* data, CarrotRequestThread* requestThread) {
      CarrotCachedRequest* cachedRequest = (CarrotCachedRequest*)request;
      [cachedRequest requestCallbackStatus:response data:data thread:requestThread];
   }];

   if(self)
   {
      self.requestId = requestId;
      self.dateIssued = dateIssued;
      self.retryCount = retryCount;
      self.cacheId = cacheId;
   }
   return self;
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

   if(self.serviceType == CarrotRequestServiceMetrics)
   {
      switch(httpCode)
      {
         case 200:
         case 201:
         {
            [requestThread.cache removeRequestFromCache:self];
         }
         break;

         default:
         {
            [requestThread.cache addRetryInCacheForRequest:self];
         }
         break;
      }
   }
   else if(httpCode == 404)
   {
      NSLog(@"Carrot resource not found, removing request from cache.");
      [requestThread.cache removeRequestFromCache:self];
   }
   else if([[Carrot sharedInstance] updateAuthenticationStatus:httpCode])
   {
      if([Carrot sharedInstance].authenticationStatus == CarrotAuthenticationStatusReady)
      {
         [requestThread.cache removeRequestFromCache:self];
      }
      else
      {
         [requestThread.cache addRetryInCacheForRequest:self];
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
         [requestThread.cache removeRequestFromCache:self];
      }
      else
      {
         [requestThread.cache addRetryInCacheForRequest:self];
      }
   }
}

@end
