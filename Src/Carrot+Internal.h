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

@interface Carrot ()

@property (strong, nonatomic) NSString* appId;
@property (nonatomic, readwrite, setter=setAuthenticationStatus:) CarrotAuthenticationStatus authenticationStatus;
@property (strong, nonatomic) NSString* dataPath;
@property (strong, nonatomic) NSString* hostname;
@property (strong, nonatomic) NSString* udid;
@property (strong, nonatomic) NSString* appSecret;
@property (strong, nonatomic) NSString* urlSchemeSuffix;
@property (strong, nonatomic, readwrite) NSDictionary* facebookUser;
@property (strong, nonatomic, readwrite) NSString* accessToken;
@property (strong, nonatomic) NSString* hostUrlScheme;

- (void)setAuthenticationStatus:(CarrotAuthenticationStatus)authenticationStatus withError:(NSError*)error;
- (BOOL)updateAuthenticationStatus:(int)httpCode;

+ (NSString*)sharedAppID;
+ (NSString*)sharedAppSchemeSuffix;
+ (NSString*)debugUDID;

@end
