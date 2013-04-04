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
#import <FacebookSDK/FacebookSDK.h>

static BOOL sCarrotDidFacebookSDKAuth = NO;

NSString* Carrot_GetAccessTokenFromSession(FBSession* session)
{
   // 3.2.1
   if([FBSession instancesRespondToSelector:@selector(accessTokenData)])
   {
      return [[session accessTokenData] accessToken];
   }
   else // older versions
   {
      return [session accessToken];
   }
}

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

   // If session is available, resume it
   if([FBSession instancesRespondToSelector:@selector(openActiveSessionWithAllowLoginUI:)])
   {
      // Legacy Facebook SDK support
      if([[FBSession activeSession] openActiveSessionWithAllowLoginUI:NO])
      {
         [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession([FBSession activeSession])];
      }
   }
   else
   {
      if([FBSession openActiveSessionWithAllowLoginUI:NO])
      {
         [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession([FBSession activeSession])];
      }
   }
}

static void (^Carrot_FacebookSDKCompletionHandler)(FBSession*, FBSessionState, NSError*) = ^(FBSession* session, FBSessionState status, NSError* error)
{
   if(session && [session isOpen])
   {
      // Fetch user id for convenience of developers
      [FBRequestConnection
       startForMeWithCompletionHandler:^(FBRequestConnection* connection,
                                         id<FBGraphUser> user,
                                         NSError* error) {
          [Carrot sharedInstance].facebookId = user.id;
          [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession(session)];
       }];
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
      [[Carrot sharedInstance] setAccessToken:Carrot_GetAccessTokenFromSession(session)];
   }
   else
   {
      [[Carrot sharedInstance] setAuthenticationStatus:CarrotAuthenticationStatusUndetermined withError:error];
   }
};

int Carrot_DoFacebookAuth(int allowLoginUI, int permission)
{
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
      {
         permissionsArray = @[@"publish_actions"];
         break;
      }
      case CarrotFacebookPermissionReadWrite:
      {
         permissionsArray = @[@"email", @"publish_actions"];
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

   return Carrot_DoFacebookAuthWithPermissions(allowLoginUI, (CFArrayRef)permissionsArray);
}

int Carrot_DoFacebookAuthWithPermissions(int allowLoginUI, CFArrayRef permissions)
{
   int ret = 0;
   int permissionType = CarrotFacebookPermissionRead;

   NSArray* permissionsArray = (NSArray*)permissions;
   NSSet* publishPermissions = [NSSet setWithArray:@[@"publish_stream", @"publish_actions", @"publish_checkins", @"create_event"]];

   // Determine if this contains read, write, or both types of permissions
   if([publishPermissions intersectsSet:[NSSet setWithArray:permissionsArray]])
   {
      permissionType = CarrotFacebookPermissionPublishActions;
      for(id permission in permissionsArray)
      {
         if(![publishPermissions containsObject:permission])
         {
            permissionType = CarrotFacebookPermissionReadWrite;
            break;
         }
      }
   }

   if(permissionType == CarrotFacebookPermissionRead &&
      [FBSession respondsToSelector:@selector(openActiveSessionWithReadPermissions:allowLoginUI:completionHandler:)])
   {
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;
      NSLog(@"Opening Facebook session with read permissions: %@", permissionsArray);

      [FBSession openActiveSessionWithReadPermissions:permissionsArray
                                         allowLoginUI:allowLoginUI
                                    completionHandler:Carrot_FacebookSDKCompletionHandler];
   }
   else if(permissionType == CarrotFacebookPermissionPublishActions &&
           [[FBSession activeSession] isOpen] &&
           [FBSession instancesRespondToSelector:@selector(reauthorizeWithPublishPermissions:defaultAudience:completionHandler:)])
   {
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;

      // 3.2.1 method
      if([FBSession instancesRespondToSelector:@selector(requestNewPublishPermissions:defaultAudience:completionHandler:)])
      {
         NSLog(@"Requesting new Facebook publish permissions: %@", permissionsArray);
         [[FBSession activeSession]
          requestNewPublishPermissions:permissionsArray
                       defaultAudience:FBSessionDefaultAudienceFriends
                     completionHandler:Carrot_FacebookSDKReauthorizeHandler];
      }
      else
      {
         NSLog(@"Reauthorizing Facebook session with publish permissions: %@", permissionsArray);
         [[FBSession activeSession]
          reauthorizeWithPublishPermissions:permissionsArray
                            defaultAudience:FBSessionDefaultAudienceFriends
                          completionHandler:Carrot_FacebookSDKReauthorizeHandler];
      }
   }
   else if([FBSession respondsToSelector:@selector(openActiveSessionWithPermissions:allowLoginUI:completionHandler:)])
   {
      // Legacy FacebookSDK support
      NSLog(@"Opening Facebook session with permissions (Legacy): %@", permissionsArray);
      ret = 1;
      sCarrotDidFacebookSDKAuth = YES;
      [FBSession openActiveSessionWithPermissions:permissionsArray
                                     allowLoginUI:allowLoginUI
                                completionHandler:Carrot_FacebookSDKCompletionHandler];
   }

   return ret;
}
