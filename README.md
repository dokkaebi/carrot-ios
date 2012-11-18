Carrot integration on iOS is cake!
==========
Initialize Carrot in the main() method of your 'main.m' or 'main.mm' file

	int main(int argc, char *argv[])
	{
		@autoreleasepool {
			// Add this line here.
			[Carrot plantInApplication:[YourAppDelegate class] withSecret:@"your_app_secret"];

			return UIApplicationMain(argc, argv, nil, NSStringFromClass([YourAppDelegate class]));
		}
	}

Start making Carrot calls!

	// ...a user has done something to earn an achievement
	[[Carrot sharedInstance] postAchievement:@"your_carrot_achievement_id"];
