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
#import <objc/runtime.h>

extern void Carrot_HandleApplicationDidBecomeActive();

@interface CarrotAppDelegateHooks : NSObject

- (BOOL)application:(UIApplication*)application
            openURL:(NSURL*)url
  sourceApplication:(NSString*)sourceApplication
         annotation:(id)annotation;

- (BOOL)application:(UIApplication*)application handleOpenURL:(NSURL *)url;

- (void)applicationDidBecomeActive:(UIApplication*)application;

- (void)application:(UIApplication*)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData*)deviceToken;

- (void)applicationDidEnterBackground:(UIApplication*)application;
@end

static IMP sHostAppOpenURLIMP = NULL;
static IMP sHostAppDepOpenURLIMP = NULL;
static IMP sHostDBAIMP = NULL;
static IMP sHostAppPushRegIMP = NULL;
static IMP sHostDEBIMP = NULL;

void Carrot_Plant(Class appDelegateClass, NSString* appSecret)
{
   // Pass appSecret to Carrot
   [[Carrot sharedInstance] setAppSecret:appSecret];

   // Install hooks
   Protocol* uiAppDelegateProto = objc_getProtocol("UIApplicationDelegate");

   // application:openURL:sourceApplication:annotation:
   struct objc_method_description appOpenURLMethod = protocol_getMethodDescription(uiAppDelegateProto, @selector(application:openURL:sourceApplication:annotation:), NO, YES);

   Method ctAppOpenURL = class_getInstanceMethod([CarrotAppDelegateHooks class], appOpenURLMethod.name);
   sHostAppOpenURLIMP = class_replaceMethod(appDelegateClass, appOpenURLMethod.name, method_getImplementation(ctAppOpenURL), appOpenURLMethod.types);

   // application:handleOpenURL: (depricated)
   struct objc_method_description appDepOpenURLMethod = protocol_getMethodDescription(uiAppDelegateProto, @selector(application:handleOpenURL:), NO, YES);

   Method ctAppDepOpenURL = class_getInstanceMethod([CarrotAppDelegateHooks class], appDepOpenURLMethod.name);
   sHostAppDepOpenURLIMP = class_replaceMethod(appDelegateClass, appDepOpenURLMethod.name, method_getImplementation(ctAppDepOpenURL), appDepOpenURLMethod.types);

   // applicationDidBecomeActive:
   struct objc_method_description appDBAMethod = protocol_getMethodDescription(uiAppDelegateProto, @selector(applicationDidBecomeActive:), NO, YES);

   Method ctAppDBA = class_getInstanceMethod([CarrotAppDelegateHooks class], appDBAMethod.name);
   sHostDBAIMP = class_replaceMethod(appDelegateClass, appDBAMethod.name, method_getImplementation(ctAppDBA), appDBAMethod.types);

   // application:didRegisterForRemoteNotificationsWithDeviceToken:
   struct objc_method_description appPushRegMethod = protocol_getMethodDescription(uiAppDelegateProto, @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:), NO, YES);

   Method ctAppPushReg = class_getInstanceMethod([CarrotAppDelegateHooks class], appPushRegMethod.name);
   sHostAppPushRegIMP = class_replaceMethod(appDelegateClass, appPushRegMethod.name, method_getImplementation(ctAppPushReg), appPushRegMethod.types);

   // applicationDidEnterBackground:
   struct objc_method_description appDEBMethod = protocol_getMethodDescription(uiAppDelegateProto, @selector(applicationDidEnterBackground:), NO, YES);

   Method ctAppDEB = class_getInstanceMethod([CarrotAppDelegateHooks class], appDEBMethod.name);
   sHostDEBIMP = class_replaceMethod(appDelegateClass, appDEBMethod.name, method_getImplementation(ctAppDEB), appDEBMethod.types);
}

@implementation CarrotAppDelegateHooks

- (BOOL)application:(UIApplication*)application
            openURL:(NSURL*)url
  sourceApplication:(NSString*)sourceApplication
         annotation:(id)annotation
{
   BOOL ret = [[Carrot sharedInstance] handleOpenURL:url];
   if(sHostAppOpenURLIMP)
   {
      ret |= (BOOL)sHostAppOpenURLIMP(self, @selector(application:openURL:sourceApplication:annotation:), application, url, sourceApplication, annotation);
   }
   return ret;
}

- (BOOL)application:(UIApplication*)application handleOpenURL:(NSURL*)url
{
   BOOL ret = [[Carrot sharedInstance] handleOpenURL:url];
   if(sHostAppDepOpenURLIMP)
   {
      ret |= (BOOL)sHostAppDepOpenURLIMP(self, @selector(application:handleOpenURL:),
                                      application, url);
   }
   return ret;
}

- (void)applicationDidBecomeActive:(UIApplication*)application
{
   [[Carrot sharedInstance] beginApplicationSession:application];
   Carrot_HandleApplicationDidBecomeActive();
   if(sHostDBAIMP)
   {
      sHostDBAIMP(self, @selector(applicationDidBecomeActive:), application);
   }
}

- (void)application:(UIApplication*)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData*)deviceToken {
   [[Carrot sharedInstance] setDevicePushToken:deviceToken];
   if(sHostAppPushRegIMP)
   {
      sHostAppPushRegIMP(self, @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:), application, deviceToken);
   }
}

- (void)applicationDidEnterBackground:(UIApplication*)application
{
   [[Carrot sharedInstance] endApplicationSession:application];
   if(sHostDEBIMP)
   {
      sHostDEBIMP(self, @selector(applicationDidEnterBackground:), application);
   }
}

@end
