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

@interface CarrotCAPIDelegate : NSObject <CarrotDelegate>
@property (assign, nonatomic) CarrotAuthStatusPtr authStatus;
@property (assign, nonatomic) CarrotAppLinkPtr appLink;
@property (assign, nonatomic) const void* context;
@end

@implementation CarrotCAPIDelegate

+ (CarrotCAPIDelegate*)sharedInstance
{
   static CarrotCAPIDelegate* sharedInstance = nil;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      sharedInstance = [[CarrotCAPIDelegate alloc] init];
   });
   return sharedInstance;
}

- (void)authenticationStatusChanged:(int)status withError:(NSError*)error
{
   if(_authStatus)
   {
      dispatch_async(dispatch_get_main_queue(), ^{
         _authStatus(_context, status, error);
      });
   }
}

- (void)applicationLinkRecieved:(NSURL*)targetURL
{
   if(_appLink)
   {
      dispatch_async(dispatch_get_main_queue(), ^{
         _appLink(_context, [[targetURL absoluteString] UTF8String]);
      });
   }
}

@end

void Carrot_setSharedAppID(const char* appID)
{
   [Carrot setSharedAppID:[NSString stringWithUTF8String:appID]];
}

int Carrot_AuthStatus()
{
   return [Carrot sharedInstance].authenticationStatus;
}

void Carrot_SetAppSecret(const char* appSecret)
{
   [[Carrot sharedInstance] setAppSecret:[NSString stringWithUTF8String:appSecret]];
}

void Carrot_SetAccessToken(const char* accessToken)
{
   [[Carrot sharedInstance] setAccessToken:[NSString stringWithUTF8String:accessToken]];
}

int Carrot_PostAchievement(const char* achievementId)
{
   return [[Carrot sharedInstance] postAchievement:[NSString stringWithUTF8String:achievementId]];
}

int Carrot_PostHighScore(unsigned int score)
{
   return [[Carrot sharedInstance] postHighScore:score];
}

int Carrot_PostInstanceAction(const char* actionId, const char* actionPropertiesJson,
                              const char* objectInstanceId)
{
   NSError* error = nil;
   NSDictionary* actionProperties = nil;
   if(actionPropertiesJson)
   {
      actionProperties = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:actionPropertiesJson] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
   }

   if(error)
   {
      NSLog(@"Error converting actionPropertiesJson to NSDictionary: %@", error);
      return 0;
   }

   return [[Carrot sharedInstance] postAction:[NSString stringWithUTF8String:actionId]
                               withProperties:actionProperties
                            forObjectInstance:[NSString stringWithUTF8String:objectInstanceId]];
}

int Carrot_PostCreateAction(const char* actionId, const char* actionPropertiesJson,
                            const char* objectId, const char* objectPropertiesJson,
                            const char* objectInstanceId)
{
   NSError* error = nil;
   NSDictionary* actionProperties = nil;
   NSDictionary* objectProperties = nil;
   NSString* objectInstanceIdString = nil;
   if(actionPropertiesJson)
   {
      actionProperties = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:actionPropertiesJson] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
   }

   if(error)
   {
      NSLog(@"Error converting actionPropertiesJson to NSDictionary: %@", error);
      return 0;
   }

   objectProperties = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:objectPropertiesJson] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
   if(error)
   {
      NSLog(@"Error converting objectPropertiesJson to NSDictionary: %@", error);
      return 0;
   }

   if(objectInstanceId)
   {
      objectInstanceIdString = [NSString stringWithUTF8String:objectInstanceId];
   }

   return [[Carrot sharedInstance] postAction:[NSString stringWithUTF8String:actionId]
                               withProperties:actionProperties
                           creatingInstanceOf:[NSString stringWithUTF8String:objectId]
                               withProperties:objectProperties
                                andInstanceId:objectInstanceIdString];
}

void Carrot_AssignFnPtrDelegate(const void* context, CarrotAuthStatusPtr authStatus,
                                CarrotAppLinkPtr appLink)
{
   [CarrotCAPIDelegate sharedInstance].context = context;
   [CarrotCAPIDelegate sharedInstance].authStatus = authStatus;
   [CarrotCAPIDelegate sharedInstance].appLink = appLink;
   [Carrot sharedInstance].delegate = [CarrotCAPIDelegate sharedInstance];
}

int Carrot_LikeGame()
{
   return [[Carrot sharedInstance] likeGame];
}

int Carrot_LikePublisher()
{
   return [[Carrot sharedInstance] likePublisher];
}

int Carrot_LikeAchievement(const char* achievementId)
{
   return [[Carrot sharedInstance] likeAchievement:[NSString stringWithUTF8String:achievementId]];
}

int Carrot_LikeObject(const char* objectInstanceId)
{
   return [[Carrot sharedInstance] likeObject:[NSString stringWithUTF8String:objectInstanceId]];
}
