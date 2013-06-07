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
#import "OpenUDID.h"
#import "Reachability.h"

#define kCarrotDefaultHostname @"gocarrot.com"

extern void Carrot_Plant(Class appDelegateClass, NSString* appSecret);
extern void Carrot_GetFBAppId(NSMutableString* outString);
extern BOOL Carrot_HandleOpenURLFacebookSDK(NSURL* url);
extern NSString* URLEscapedString(NSString* inString);

@interface Carrot ()

@property (strong, nonatomic) CarrotRequestThread* requestThread;
@property (strong, nonatomic) CarrotReachability* reachability;
@property (nonatomic) CarrotAuthenticationStatus lastAuthStatusReported;

@end

static NSString* sCarrotAppID = nil;
static NSString* sCarrotURLSchemeSuffix = nil;
static NSString* sCarrotDebugUDID = nil;

@implementation Carrot

+ (Carrot*)sharedInstance
{
   static Carrot* sharedInstance = nil;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      sharedInstance = [[Carrot alloc] init];
   });
   return sharedInstance;
}

+ (void)setSharedAppID:(NSString*)appID
{
   sCarrotAppID = appID;
}

+ (NSString*)sharedAppID
{
   if(!sCarrotAppID)
   {
      NSMutableString* retrievedAppId = [[NSMutableString alloc] init];
      Carrot_GetFBAppId(retrievedAppId);
      return retrievedAppId;
   }
   return sCarrotAppID;
}

+ (void)setSharedAppSchemeSuffix:(NSString*)schemeSuffix
{
   sCarrotURLSchemeSuffix = schemeSuffix;
}

+ (NSString*)sharedAppSchemeSuffix
{
   return sCarrotURLSchemeSuffix;
}

+ (void)plantInApplication:(Class)appDelegateClass withSecret:(NSString*)appSecret
{
   Carrot_Plant(appDelegateClass, appSecret);
}

+ (void)plant:(NSString*)appID inApplication:(Class)appDelegateClass withSecret:(NSString*)appSecret
{
   [Carrot setSharedAppID:appID];
   Carrot_Plant(appDelegateClass, appSecret);
}

+ (void)plant:(NSString*)appID inApplication:(Class)appDelegateClass urlSchemeSuffix:(NSString*)urlSchemeSuffix withSecret:(NSString*)appSecret
{
   [Carrot setSharedAppSchemeSuffix:urlSchemeSuffix];
   [Carrot setSharedAppID:appID];
   Carrot_Plant(appDelegateClass, appSecret);
}

+ (BOOL)performFacebookAuthAllowingUI:(BOOL)allowLoginUI
                        forPermission:(CarrotFacebookPermissionType)permission
{
   return Carrot_DoFacebookAuth(allowLoginUI, permission);
}

+ (BOOL)performFacebookAuthAllowingUI:(BOOL)allowLoginUI
                   forPermissionArray:(NSArray*)permissionArray
{
   return Carrot_DoFacebookAuthWithPermissions(allowLoginUI, (__bridge CFArrayRef)permissionArray);
}

+ (NSString*)debugUDID
{
   return sCarrotDebugUDID;
}

+ (void)setDebugUDID:(NSString*)debugUDID
{
   sCarrotDebugUDID = debugUDID;
}

- (id)init
{
   NSString* appId = [Carrot sharedAppID];

   if(!appId || appId.length < 1)
   {
      NSException *exception = [NSException exceptionWithName:@"MissingAppIDException"
                                                       reason:@"'FacebookAppID' not found in Info.plist, and no AppID assigned via [FBSession setDefaultAppID:]. Use [Carrot plantInApplication:appId:withSecret:]."
                                                     userInfo: nil];
      @throw exception;
      return nil;
   }

   return [self initWithAppId:appId
                    appSecret:nil
              urlSchemeSuffix:[Carrot sharedAppSchemeSuffix]
                hostnameOrNil:nil
               debugUDIDOrNil:[Carrot debugUDID]];
}

- (id)initWithAppId:(NSString*)appId appSecret:(NSString*)appSecret urlSchemeSuffix:(NSString*)urlSchemeSuffix hostnameOrNil:(NSString*)hostnameOrNil debugUDIDOrNil:(NSString*)debugUDIDOrNil
{
   self = [super init];
   if(self)
   {
      _authenticationStatus = CarrotAuthenticationStatusUndetermined;
      self.lastAuthStatusReported = _authenticationStatus;
      self.hostname = (hostnameOrNil ? hostnameOrNil : kCarrotDefaultHostname);
      self.appId = appId;
      self.appSecret = appSecret;
      self.udid = (debugUDIDOrNil == nil ? [CarrotOpenUDID value] : debugUDIDOrNil);
      self.urlSchemeSuffix = urlSchemeSuffix;

      // Get data path
      NSArray* searchPaths = [[NSFileManager defaultManager] URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask];
      self.dataPath = [[[searchPaths lastObject] path] stringByAppendingPathComponent:@"Carrot"];

      NSError* error = nil;
      BOOL succeeded = [[NSFileManager defaultManager] createDirectoryAtPath:self.dataPath
                                                 withIntermediateDirectories:YES
                                                                  attributes:nil
                                                                       error:&error];
      if(!succeeded)
      {
         NSLog(@"Unable to create Carrot data path: %@.", error);
         return nil;
      }

      self.requestThread = [[CarrotRequestThread alloc] initWithCarrot:self];
      if(!self.requestThread)
      {
         NSLog(@"Unable to create Carrot request thread.");
         return nil;
      }

      // Start up Reachability monitor
      self.reachability = [CarrotReachability reachabilityWithHostname:self.hostname];
      self.reachability.reachableBlock = ^(CarrotReachability* reach)
      {
         [[Carrot sharedInstance] validateUser];
      };
      self.reachability.unreachableBlock = ^(CarrotReachability* reach)
      {
         self.authenticationStatus = CarrotAuthenticationStatusUndetermined;
      };
      [self.reachability startNotifier];
   }
   return self;
}

- (void)dealloc
{
   [self.requestThread stop];
   while(self.requestThread.isRunning)
   {
      sleep(1);
   }
   self.requestThread = nil;

   [self.reachability stopNotifier];
   self.reachability = nil;

   self.dataPath = nil;
   self.accessToken = nil;
   self.hostname = nil;
   self.appId = nil;
   self.udid = nil;
   self.appSecret = nil;
   self.urlSchemeSuffix = nil;
}

- (void)setAccessToken:(NSString*)accessToken
{
   _accessToken = accessToken;

   if(self.authenticationStatus != CarrotAuthenticationStatusReady)
   {
      [self validateUser];
   }
}

- (void)setDelegate:(NSObject <CarrotDelegate>*)delegate
{
   _delegate = delegate;
   self.lastAuthStatusReported = CarrotAuthenticationStatusUndetermined;
   [self setAuthenticationStatus:_authenticationStatus];
}

- (void)setAppSecret:(NSString*)appSecret
{
   _appSecret = appSecret;
}

- (void)setAuthenticationStatus:(CarrotAuthenticationStatus)authenticationStatus
{
   [self setAuthenticationStatus:authenticationStatus withError:nil];
}

- (void)setAuthenticationStatus:(CarrotAuthenticationStatus)authenticationStatus
                      withError:(NSError*)error
{
   @synchronized(self)
   {
      _authenticationStatus = authenticationStatus;
      if(_authenticationStatus == CarrotAuthenticationStatusReady)
      {
         [self.requestThread start];
      }
      else
      {
         [self.requestThread stop];
      }
   }

   if(self.lastAuthStatusReported != _authenticationStatus &&
      [[Carrot sharedInstance].delegate respondsToSelector:@selector(authenticationStatusChanged:withError:)])
   {
      self.lastAuthStatusReported = _authenticationStatus;
      [[Carrot sharedInstance].delegate authenticationStatusChanged:_authenticationStatus
                                                          withError:error];
   }
}

- (BOOL)updateAuthenticationStatus:(int)httpCode
{
   BOOL ret = YES;
   switch(httpCode)
   {
      case 200:
      case 201:
      {
         // Everything is in order, we are online
         self.authenticationStatus = CarrotAuthenticationStatusReady;
         break;
      }
      case 401: // Unauthorized
      {
         // The user has not allowed the 'publish_actions' permission.
         self.authenticationStatus = CarrotAuthenticationStatusReadOnly;
         break;
      }
      case 405: // Method Not Allowed
      {
         // The user has not authorized the application, or deauthorized the application.
         self.authenticationStatus = CarrotAuthenticationStatusNotAuthorized;
         break;
      }
      default:
      {
         ret = NO;
      }
   }
   return ret;
}

- (BOOL)handleOpenURL:(NSURL*)url
{
   BOOL ret = Carrot_HandleOpenURLFacebookSDK(url);
   if([url.scheme compare:[NSString stringWithFormat:@"fb%@%@", self.appId, self.urlSchemeSuffix]] == 0)
   {
      @try
      {
         NSMutableDictionary* queryParams = [[NSMutableDictionary alloc] init];

         // This block grabs the Auth case, where it's fb<AppID><Suffix>://authorize#params
         for(NSString* param in [url.fragment componentsSeparatedByString:@"&"])
         {
            NSArray* qparts = [param componentsSeparatedByString:@"="];
            [queryParams setObject:(qparts.count > 1 ? [qparts objectAtIndex:1] : nil)
                            forKey:[qparts objectAtIndex:0]];
         }

         // This block grabs the deep-link case, where it's fb<AppID><Suffix>://authorize?params
         for(NSString* param in [url.query componentsSeparatedByString:@"&"])
         {
            NSArray* qparts = [param componentsSeparatedByString:@"="];
            [queryParams setObject:(qparts.count > 1 ? [qparts objectAtIndex:1] : nil)
                            forKey:[qparts objectAtIndex:0]];
         }

         // In either case, assign access token
         [self setAccessToken:[queryParams objectForKey:@"access_token"]];

         // Check for deep linking
         NSString* target_url = [queryParams objectForKey:@"target_url"];
         if(target_url)
         {
            NSURL* targetURL = [NSURL URLWithString:[target_url stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            if([self.delegate respondsToSelector:@selector(applicationLinkRecieved:)])
            {
               [self.delegate applicationLinkRecieved:targetURL];
            }
         }
         return YES;
      }
      @catch (NSException* e) {}
   }
   else if([url.scheme compare:[NSString stringWithFormat:@"carrot%@%@",
                                self.appId, self.urlSchemeSuffix]] == 0)
   {
      @try
      {
         NSMutableDictionary* queryParams = [[NSMutableDictionary alloc] init];

         for(NSString* param in [url.query componentsSeparatedByString:@"&"])
         {
            NSArray* qparts = [param componentsSeparatedByString:@"="];
            [queryParams setObject:(qparts.count > 1 ? [qparts objectAtIndex:1] : nil)
                            forKey:[qparts objectAtIndex:0]];
         }

         NSString* target_url = [queryParams objectForKey:@"target_url"];
         if(target_url)
         {
            NSURL* targetURL = [NSURL URLWithString:[target_url stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            if([self.delegate respondsToSelector:@selector(applicationLinkRecieved:)])
            {
               [self.delegate applicationLinkRecieved:targetURL];
            }
         }
         return YES;
      }
      @catch (NSException* e) {}
   }
   return ret;
}

- (void)validateUser
{
   if(!self.accessToken) return;

   static dispatch_semaphore_t validateSema;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      validateSema = dispatch_semaphore_create(1);
   });

   NSString* urlString = [NSString stringWithFormat:@"https://%@/games/%@/users.json", self.hostname, self.appId];
   NSMutableURLRequest* urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];

   NSString* postBody = [NSString stringWithFormat:@"api_key=%@&access_token=%@", self.udid, self.accessToken];

   NSData* postData = [postBody dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
   [urlRequest setHTTPMethod:CarrotRequestTypePOST];
   [urlRequest setHTTPBody:postData];
   [urlRequest setValue:[NSString stringWithFormat:@"%d", [postData length]]
     forHTTPHeaderField:@"Content-Length"];
   [urlRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

   dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      dispatch_semaphore_wait(validateSema, DISPATCH_TIME_FOREVER);

      [NSURLConnection sendAsynchronousRequest:urlRequest
                                         queue:[NSOperationQueue mainQueue]
                             completionHandler:^(NSURLResponse* response, NSData* data, NSError* error)
       {
          NSHTTPURLResponse* httpResponse = response ? (NSHTTPURLResponse*)response : nil;
          int httpCode = httpResponse.statusCode;

          if(error)
          {
             switch(error.code)
             {
                // 401
                case NSURLErrorUserCancelledAuthentication:
                   error = nil;
                   httpCode = 401;
                   break;

                default:
                   NSLog(@"Unknown error adding Carrot user: %@", error);
                   [self setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error];
             }
          }

          if(error == nil)
          {
             if(httpCode == 404 || httpCode == 403)
             {
                // No such user || User has deauthorized game
                [self setAuthenticationStatus:CarrotAuthenticationStatusNotAuthorized];
             }
             else if(error || ![self updateAuthenticationStatus:httpCode])
             {
                NSDictionary* jsonReply = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                NSLog(@"Unknown error adding Carrot user (%d): %@", httpResponse.statusCode,
                      error ? error : jsonReply);
                [self setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error];
             }
          }

          dispatch_semaphore_signal(validateSema);
       }];
   });
}

- (void)setDevicePushToken:(NSData*)deviceToken
{
   NSString* deviceTokenString = [[[[deviceToken description]
                                    stringByReplacingOccurrencesOfString:@"<" withString:@""]
                                    stringByReplacingOccurrencesOfString:@">" withString:@""]
                                    stringByReplacingOccurrencesOfString:@" " withString:@""];
   if(deviceTokenString)
   {
      [self.requestThread addRequestForEndpoint:@"/me/devices.json"
                                        usingMethod:CarrotRequestTypePOST
                                    withPayload:@{@"device_type" : @"ios",
                                                  @"push_key" : deviceTokenString}];
   }
}

- (BOOL)postAchievement:(NSString*)achievementId
{
   return [self.requestThread addRequestForEndpoint:@"/me/achievements.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:@{@"achievement_id" : achievementId}];
}

- (BOOL)postHighScore:(NSUInteger)score
{
   NSDictionary* payload = @{@"value" : [NSNumber numberWithLong:score]};
   return [self.requestThread addRequestForEndpoint:@"/me/scores.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:payload];
}

- (BOOL)postAction:(NSString*)actionId forObjectInstance:(NSString*)objectInstanceId
{
   return [self postAction:actionId withProperties:nil forObjectInstance:objectInstanceId];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties forObjectInstance:(NSString*)objectInstanceId
{
   NSMutableDictionary* payload = [NSMutableDictionary dictionaryWithDictionary:@{
                                   @"action_id" : actionId, @"object_instance_id" : objectInstanceId}];
   if(actionProperties != nil)
   {
      [payload setObject:actionProperties forKey:@"action_properties"];
   }

   return [self.requestThread addRequestForEndpoint:@"/me/actions.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:payload];
}

- (BOOL)postAction:(NSString*)actionId creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties
{
   return [self postAction:actionId withProperties:nil creatingInstanceOf:objectTypeId withProperties:objectProperties andInstanceId:nil];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties
{
   return [self postAction:actionId withProperties:nil creatingInstanceOf:objectTypeId withProperties:objectProperties andInstanceId:nil];
}

- (BOOL)postAction:(NSString*)actionId withProperties:(NSDictionary*)actionProperties creatingInstanceOf:(NSString*)objectTypeId withProperties:(NSDictionary*)objectProperties andInstanceId:(NSString*)objectInstanceId
{
   if(!objectProperties)
   {
      NSLog(@"objectProperties must not be nil.");
      return NO;
   }

   NSArray* requiredObjectProperties = @[@"title", @"image", @"description"];
   id nilMarker = [NSNull null];
   NSArray* valuesForRequiredProperties = [objectProperties objectsForKeys:requiredObjectProperties notFoundMarker:nilMarker];
   if([valuesForRequiredProperties containsObject:nilMarker])
   {
      NSLog(@"objectProperties must contain values for: %@", requiredObjectProperties);
      return NO;
   }

   // Process object properties
   NSMutableDictionary* fullObjectProperties = [NSMutableDictionary dictionaryWithDictionary:objectProperties];
   [fullObjectProperties setObject:objectTypeId forKey:@"object_type"];

   // TODO (v2): Support image uploading
   [fullObjectProperties setObject:[objectProperties objectForKey:@"image"] forKey:@"image_url"];
   [fullObjectProperties removeObjectForKey:@"image"];

   NSMutableDictionary* payload = [NSMutableDictionary dictionaryWithDictionary:@{
                                   @"action_id" : actionId, @"object_properties" : fullObjectProperties}];

   if(objectInstanceId != nil)
   {
      [payload setObject:objectInstanceId forKey:@"object_instance_id"];
   }

   if(actionProperties != nil)
   {
      [payload setObject:actionProperties forKey:@"action_properties"];
   }

   return [self.requestThread addRequestForEndpoint:@"/me/actions.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:payload];
}

-(BOOL)likeGame
{
   return [self.requestThread addRequestForEndpoint:@"/me/like.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:@{@"object" : @"game"}];
}

-(BOOL)likePublisher
{
   return [self.requestThread addRequestForEndpoint:@"/me/like.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:@{@"object" : @"publisher"}];
}

-(BOOL)likeAchievement:(NSString*)achievementId;
{
   NSString* likeObject = [NSString stringWithFormat:@"achievement:%@", achievementId];
   return [self.requestThread addRequestForEndpoint:@"/me/like.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:@{@"object" : likeObject}];
}

-(BOOL)likeObject:(NSString*)objectInstanceId
{
   NSString* likeObject = [NSString stringWithFormat:@"object:%@", objectInstanceId];
   return [self.requestThread addRequestForEndpoint:@"/me/like.json"
                                        usingMethod:CarrotRequestTypePOST
                                        withPayload:@{@"object" : likeObject}];
}

@end
