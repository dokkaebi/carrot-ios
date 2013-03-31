
task :default => "ios:library"

namespace :ios do
  desc "Build the iOS library"
  task :library do
    sh "xcodebuild -alltargets -project Carrot-iOS.xcodeproj"
  end
end
