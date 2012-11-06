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

/**
 * @mainpage
 * Carrot integration on iOS is cake!<ol>
 * <li>  Initialize Carrot in the main() method of your 'main.m' or 'main.mm' file
 *       @code
 *       int main(int argc, char *argv[])
 *       {
 *          @autoreleasepool {
 *             // Add this line here.
 *             [Carrot plantInApplication:[YourAppDelegate class] withSecret:@"your_app_secret"];
 *
 *             return UIApplicationMain(argc, argv, nil, NSStringFromClass([YourAppDelegate class]));
 *          }
 *       }
 *       @endcode
 *
 * <li>  Start making Carrot calls!
 *       @code
 *       // ...a user has done something to earn an achievement
 *       [[Carrot sharedInstance] postAchievement:@"your_carrot_achievement_id"];
 *       @endcode
 * </ol>
 */
