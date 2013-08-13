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
#import "Carrot+Internal.h"
#import "CarrotRequestThread.h"
#import "CarrotCachedRequest.h"
#import "AmazonSDKUtil.h"
#import "Reachability.h"

#include <CommonCrypto/CommonHMAC.h>

#define kCarrotServicesHostname @"services.gocarrot.com"
#define kDefaultHostUrlScheme @"https"

@interface CarrotRequestThread ()

@property (strong, nonatomic) NSMutableArray* requestQueue;
@property (strong, nonatomic, readwrite) CarrotCache* cache;
@property (assign, nonatomic) Carrot* carrot;
@property (nonatomic) BOOL keepThreadRunning;
@property (strong, nonatomic) NSCondition* requestQueuePause;
@property (strong, nonatomic) NSString* postHostname;
@property (strong, nonatomic) NSString* metricsHostname;
@property (strong, nonatomic) NSString* authHostname;
@property (strong, nonatomic) CarrotReachability* reachability;
@property (strong, nonatomic) NSDate* lastDiscoveryDate;

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
      self.requestQueue = [[NSMutableArray alloc] init];
      self.carrot = carrot;
      self.maxRetryCount = 0; // Infinite retries by default
      self.requestQueuePause = [[NSCondition alloc] init];
      self.lastDiscoveryDate = nil;
      self.cache = carrot.cache;
      _isRunning = NO;

      // Start up Reachability monitor
      __weak typeof(self) weakSelf = self;
      self.reachability = [CarrotReachability reachabilityWithHostname:kCarrotServicesHostname];
      self.reachability.reachableBlock = ^(CarrotReachability* reach)
      {
         [weakSelf performDiscovery];
      };
      self.reachability.unreachableBlock = ^(CarrotReachability* reach)
      {
         [weakSelf stop];
      };
      [self.reachability startNotifier];
   }
   return self;
}

- (void)dealloc
{
   [self.reachability stopNotifier];
   self.reachability = nil;

   [self stop];
   self.requestQueue = nil;
}

- (void)performDiscovery
{
   NSDate* nextDiscoveryDate = [self.lastDiscoveryDate dateByAddingTimeInterval: 24 * 60 * 60];
   if(self.lastDiscoveryDate != nil &&
      ([self.lastDiscoveryDate compare:nextDiscoveryDate] == NSOrderedAscending))
   {
      return;
   }
   self.lastDiscoveryDate = [NSDate date];

   NSString* urlString = [NSString stringWithFormat:@"http://%@/services.json?sdk_version=%@&sdk_platform=%@&game_id=%@&app_version=%@&app_build=%@",
                          kCarrotServicesHostname,
                          URLEscapedString(self.carrot.version),
                          URLEscapedString([NSString stringWithFormat:@"ios_%@",[[UIDevice currentDevice] systemVersion]]),
                          URLEscapedString(self.carrot.appId),
                          URLEscapedString(self.carrot.appVersion),
                          URLEscapedString(self.carrot.appBuild)];
   NSURLRequest* request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                        timeoutInterval:120];
   [NSURLConnection sendAsynchronousRequest:request
                                      queue:[NSOperationQueue mainQueue]
                          completionHandler:^(NSURLResponse* response, NSData* data, NSError* error) {
      if(error)
      {
        NSLog(@"Unable to perform services discovery for Carrot. Carrot is in offline mode.\n%@", error);
      }
      else
      {
        NSDictionary* services = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:kNilOptions
                                                                   error:&error];
        if(error)
        {
           NSLog(@"Unable to perform services discovery for Carrot. Carrot is in offline mode.\n%@", error);
        }
        else
        {
           self.postHostname = [services objectForKey:@"post"] == [NSNull null] ? nil : [services objectForKey:@"post"];
           self.authHostname = [services objectForKey:@"auth"] == [NSNull null] ? nil : [services objectForKey:@"auth"];
           self.metricsHostname = [services objectForKey:@"metrics"] == [NSNull null] ? nil : [services objectForKey:@"metrics"];

           [self start];
           [self.carrot validateUser];
        }
      }
   }];
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

- (void)signal
{
   if(self.isRunning)
   {
      [self.requestQueuePause lock];
      [self.requestQueuePause signal];
      [self.requestQueuePause unlock];
   }
}

- (NSString*)hostForServiceType:(CarrotRequestServiceType)serviceType
{
   switch(serviceType)
   {
      case CarrotRequestServiceAuth:    return self.authHostname;
      case CarrotRequestServiceMetrics: return self.metricsHostname;
      case CarrotRequestServicePost:    return self.postHostname;
   }
}

- (BOOL)addRequestForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint usingMethod:(NSString*)method withPayload:(NSDictionary*)payload
{
   return [self addRequestForService:serviceType atEndpoint:endpoint usingMethod:method withPayload:payload callback:nil atFront:NO];
}

- (BOOL)addRequestForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint  usingMethod:(NSString*)method withPayload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback
{
   return [self addRequestForService:serviceType atEndpoint:endpoint usingMethod:method withPayload:payload callback:callback atFront:NO];
}

- (BOOL)addRequestForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint  usingMethod:(NSString*)method withPayload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback atFront:(BOOL)atFront
{
   BOOL ret = YES;
   if(method == CarrotRequestTypeGET)
   {

      CarrotRequest* request = [CarrotRequest requestForService:serviceType
                                                     atEndpoint:endpoint
                                                    usingMethod:method
                                                    withPayload:payload
                                                       callback:callback];
      if(request)
      {
         [self addRequestInQueue:request atFront:atFront];
      }
   }
   else
   {
      CarrotCachedRequest* cachedRequest =
      [CarrotCachedRequest requestForService:serviceType
                                  atEndpoint:endpoint
                                 withPayload:payload
                                     inCache:self.cache];

      if(cachedRequest)
      {
         [self addRequestInQueue:cachedRequest atFront:atFront];
      }

      ret = (cachedRequest != nil);
   }

   return ret;
}

- (void)addRequestInQueue:(CarrotRequest*)request atFront:(BOOL)atFront
{
   if(request != nil && request.serviceType <= self.carrot.authenticationStatus)
   {
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
         @synchronized(self.requestQueue)
         {
            if(atFront)
            {
               [self.requestQueue insertObject:request atIndex:0];
            }
            else
            {
               [self.requestQueue addObject:request];
            }
         }
         [self signal];
      });
   }
}

- (void)loadQueueFromCache
{
   @synchronized(self.requestQueue)
   {
      [self.cache addRequestsForAuthStatus:self.carrot.authenticationStatus
                                 intoArray:self.requestQueue];
   }
}

- (NSString*)signedPostBody:(CarrotRequest*)request forHost:(NSString*)host
{
   NSString* path = request.endpoint;
   if(path == nil || path.length < 1) path = @"/";

   // Build query dict
   NSDictionary* commonQueryDict = @{
      @"api_key" : self.carrot.udid,
      @"game_id" : self.carrot.appId
   };

   NSMutableDictionary* queryParamDict = [NSMutableDictionary dictionaryWithDictionary:request.payload];
   [queryParamDict addEntriesFromDictionary:commonQueryDict];

   if(request.method != CarrotRequestTypePOST)
   {
      [queryParamDict addEntriesFromDictionary:@{@"_method" : request.method}];
   }

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

   NSString* stringToSign = [NSString stringWithFormat:@"%@\n%@\n%@\n%@", @"POST", host, path,
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

   while(self.keepThreadRunning)
   {
      @autoreleasepool
      {
         CarrotCachedRequest* request = nil;

         @synchronized(self.requestQueue)
         {
            if(self.requestQueue.count > 0)
            {
               request = [self.requestQueue objectAtIndex:0];
               [self.requestQueue removeObjectAtIndex:0];
            }
         }

         if(request)
         {
            [self processRequest:request];
         }
         else
         {
            [self.requestQueuePause lock];

            // Populate cache
            [self loadQueueFromCache];

            // If queue is still empty, wait until it's not empty.
            while(self.requestQueue.count < 1 && self.keepThreadRunning) {
               [self.requestQueuePause wait];
            }
            [self.requestQueuePause unlock];
         }

         // 'jitter' request rate
         double val = ((double)arc4random() / ARC4RANDOM_MAX) - 0.5;
         [NSThread sleepForTimeInterval:1.0 + val];
      }
   }
   _isRunning = NO;
}

- (void)processRequest:(CarrotRequest*)request
{
   NSString* host = [self hostForServiceType:request.serviceType];

   // If host is nil or empty, the server said "don't send me these now"
   if(!(host && host.length)) return;

   NSString* postBody = [self signedPostBody:request forHost:host];

   NSMutableURLRequest* preppedRequest = nil;

   NSData* postData = [postBody dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
   preppedRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@%@", kDefaultHostUrlScheme, host, request.endpoint]]];

   [preppedRequest setHTTPBody:postData];
   [preppedRequest setValue:[NSString stringWithFormat:@"%d", [postData length]]
         forHTTPHeaderField:@"Content-Length"];
   [preppedRequest setValue:@"application/x-www-form-urlencoded"
         forHTTPHeaderField:@"Content-Type"];

   [preppedRequest setHTTPMethod:@"POST"];

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
   if(error && error.code != NSURLErrorUserCancelledAuthentication)
   {
      NSLog(@"Error submitting Carrot request: %@", error);
   }
   else if(request.callback)
   {
      request.callback(request, response, data, self);
   }
}

@end
