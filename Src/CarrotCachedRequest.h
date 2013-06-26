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

#import <Foundation/Foundation.h>
#import "CarrotRequest.h"
#include <sqlite3.h>

@interface CarrotCachedRequest : CarrotRequest

@property (strong, nonatomic, readonly) NSString* requestId;
@property (strong, nonatomic, readonly) NSDate* dateIssued;
@property (nonatomic, readonly) NSUInteger retryCount;

+ (id)requestForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint withPayload:(NSDictionary*)payload inCache:(sqlite3*)cache synchronizingOnObject:(id)synchObject;

+ (NSArray*)requestsInCache:(sqlite3*)cache forAuthStatus:(CarrotAuthenticationStatus)authStatus;
+ (BOOL)prepareCache:(sqlite3*)cache;

- (BOOL)removeFromCache:(sqlite3*)cache;
- (BOOL)addRetryInCache:(sqlite3*)cache;

- (NSString*)description;

@end
