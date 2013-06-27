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

#import "CarrotRequest.h"
#import "Carrot+Internal.h"

NSString* CarrotRequestTypeGET = @"GET";
NSString* CarrotRequestTypePOST = @"POST";

@interface CarrotRequest ()

@property (nonatomic, readwrite) CarrotRequestServiceType serviceType;
@property (strong, nonatomic, readwrite) NSString* endpoint;
@property (strong, nonatomic, readwrite) NSDictionary* payload;
@property (strong, nonatomic, readwrite) NSString* method;
@property (strong, nonatomic, readwrite) CarrotRequestResponse callback;

@end

@implementation CarrotRequest

+ (id)requestForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint usingMethod:(NSString*)method withPayload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback
{
   return [[CarrotRequest alloc] initForService:serviceType
                                     atEndpoint:endpoint
                                    usingMethod:method
                                        payload:payload
                                       callback:callback];
}

+ (NSDictionary*)finalPayloadForPayload:(NSDictionary*)payload
{
   NSDictionary* commonPayload = @{
      @"version" : [Carrot sharedInstance].appVersion,
      @"build" : [Carrot sharedInstance].appBuild,
      @"tag" : [Carrot sharedInstance].appTag ? [Carrot sharedInstance].appTag : @"none"
   };
   NSMutableDictionary* finalPayload = [NSMutableDictionary dictionaryWithDictionary:commonPayload];
   [finalPayload addEntriesFromDictionary:payload];
   return finalPayload;
}

- (id)initForService:(CarrotRequestServiceType)serviceType atEndpoint:(NSString*)endpoint usingMethod:(NSString*)method payload:(NSDictionary*)payload callback:(CarrotRequestResponse)callback
{
   self = [super init];
   if(self)
   {
      self.serviceType = serviceType;
      self.endpoint = endpoint;
      self.payload = [CarrotRequest finalPayloadForPayload:payload];
      self.method = method;
      self.callback = callback;
   }
   return self;
}


- (NSString*)description
{
   return [NSString stringWithFormat:@"Carrot Request: {\n\t'request_servicetype':'%d'\n\t'request_endpoint':'%@',\n\t'request_method':'%@',\n\t'request_payload':'%@'\n}", self.serviceType, self.endpoint, self.method, self.payload];
}

@end
