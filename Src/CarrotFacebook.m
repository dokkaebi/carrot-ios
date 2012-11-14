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
#import <FacebookSDK/FacebookSDK.h>

static BOOL sCarrotDidFacebookSDKAuth = NO;

void Carrot_GetFBAppId(NSMutableString* outString)
{
   [outString setString:[FBSession defaultAppID]];
}

BOOL Carrot_HandleOpenURLFacebookSDK(NSURL* url)
{
   if(sCarrotDidFacebookSDKAuth)
   {
      return [[FBSession activeSession] handleOpenURL:url];
   }
   return NO;
}

void Carrot_HandleApplicationDidBecomeActive()
{
  [[FBSession activeSession] handleDidBecomeActive];
}

static void (^Carrot_FacebookSDKCompletionHandler)(FBSession*, FBSessionState, NSError*) = ^(FBSession* session, FBSessionState status, NSError* error)
{
   if(session && [session isOpen])
   {
      [[Carrot sharedInstance] setAccessToken:[session accessToken]];
   }
   else
   {
      [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error];
   }
};

static void (^Carrot_FacebookSDKReauthorizeHandler)(FBSession*, NSError*) = ^(FBSession* session, NSError* error)
{
   if(session && [session isOpen])
   {
      [[Carrot sharedInstance] setAccessToken:[session accessToken]];
   }
   else
   {
      [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error];
   }
};

int Carrot_DoFacebookAuth(int allowLoginUI, int permission)
{
   int ret = 0;

   NSArray* permissionsArray = nil;
   switch(permission)
   {
      case CarrotFacebookPermissionRead:
      {
         // 'email' is only here because we are required to request a basic
         // read permission, and this is the one people are used to giving.
         permissionsArray = @[@"email"];
         break;
      }
      case CarrotFacebookPermissionPublishActions:
      case CarrotFacebookPermissionReadWrite:
      {
         permissionsArray = @[@"publish_actions"];
         break;
      }

      default:
      {
#ifdef DEBUG
         NSException *exception = [NSException exceptionWithName:@"BadPermissionException"
                                                          reason:@"Permission request must be CarrotFacebookPermissionRead, CarrotFacebookPermissionReadWrite or CarrotFacebookPermissionPublishActions."
                                                        userInfo:nil];
         @throw exception;
#endif
      }
   }

   if(permission == CarrotFacebookPermissionRead &&
      [FBSession respondsToSelector:@selector(openActiveSessionWithReadPermissions:allowLoginUI:completionHandler:)])
   {
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;

      [FBSession openActiveSessionWithReadPermissions:permissionsArray
                                         allowLoginUI:allowLoginUI
                                    completionHandler:Carrot_FacebookSDKCompletionHandler];
   }
   else if(permission == CarrotFacebookPermissionPublishActions &&
           [[FBSession activeSession] isOpen] &&
           [FBSession instancesRespondToSelector:@selector(reauthorizeWithPublishPermissions:defaultAudience:completionHandler:)])
   {
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;
      [[FBSession activeSession]
       reauthorizeWithPublishPermissions:permissionsArray
                         defaultAudience:FBSessionDefaultAudienceFriends
                       completionHandler:Carrot_FacebookSDKReauthorizeHandler];
   }
   else if([FBSession respondsToSelector:@selector(openActiveSessionWithPermissions:allowLoginUI:completionHandler:)])
   {
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;
      [FBSession openActiveSessionWithPermissions:@[@"publish_actions"]
                                     allowLoginUI:allowLoginUI
                                completionHandler:Carrot_FacebookSDKCompletionHandler];
   }

   return ret;
}
