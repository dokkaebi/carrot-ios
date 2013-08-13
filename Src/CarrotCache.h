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
#include <sqlite3.h>

@class CarrotCachedRequest;

@interface CarrotCache : NSObject

@property (strong, nonatomic, readonly) NSDate* installDate;
@property (nonatomic, readonly) BOOL installMetricSent;
@property (nonatomic, readonly) sqlite3* sqliteDb;

+ (id)cacheWithPath:(NSString*)path;

- (sqlite_uint64)cacheRequest:(CarrotCachedRequest*)request;
- (BOOL)addRetryInCacheForRequest:(CarrotCachedRequest*)request;
- (BOOL)removeRequestFromCache:(CarrotCachedRequest*)request;
- (void)markAppInstalled;
- (uint64_t)addRequestsForAuthStatus:(CarrotAuthenticationStatus)authStatus intoArray:(NSMutableArray*)cacheArray;

@end
