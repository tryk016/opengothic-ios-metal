#import <UIKit/UIKit.h>

#include "game/graphics/iosremainingmaterialcensus.h"

#include <array>
#include <cstring>
#include <cstdio>
#include <limits>
#include <optional>
#include <string>

#if !defined(OPENGOTHIC_RENDERER_IOS_BUILD_SHA)
#define OPENGOTHIC_RENDERER_IOS_BUILD_SHA "local"
#endif

namespace {

constexpr std::array<Material::AlphaFunc,IOSRemainingMaterialCount> Materials = {
  Material::Water,Material::Ghost,Material::Multiply,Material::Multiply2,
  Material::Transparent,
  };
constexpr std::array<IOSSceneSourceKind,IOSRemainingMaterialKindCount> Kinds = {
  IOSSceneSourceKind::Landscape,IOSSceneSourceKind::Static,
  IOSSceneSourceKind::Movable,IOSSceneSourceKind::Animated,
  IOSSceneSourceKind::Particle,IOSSceneSourceKind::Morph,
  IOSSceneSourceKind::Unsupported,
  };
constexpr std::array<IOSSceneTextureAnimationMode,
                     IOSRemainingMaterialModeCount> Modes = {
  IOSSceneTextureAnimationMode::None,
  IOSSceneTextureAnimationMode::FrameOnly,
  IOSSceneTextureAnimationMode::UvOnly,
  IOSSceneTextureAnimationMode::FrameAndUv,
  };
constexpr std::array<const char*,IOSRemainingMaterialCount> MaterialNames = {
  "Water","Ghost","Multiply","Multiply2","Transparent",
  };
constexpr std::array<const char*,IOSRemainingMaterialKindCount> KindNames = {
  "Landscape","Static","Movable","Animated","Particle","Morph",
  "Unsupported",
  };

[[noreturn]] void fail(NSString* message) {
  @throw [NSException exceptionWithName:@"RemainingMaterialCensusFailure"
                                  reason:message userInfo:nil];
  }

NSArray* exactArray(NSDictionary* root, NSString* key, NSUInteger count) {
  const id value = root[key];
  if(![value isKindOfClass:NSArray.class] || [value count]!=count)
    fail([NSString stringWithFormat:@"%@ array differs",key]);
  return value;
  }

uint64_t exactUint(id value, NSString* label) {
  if(![value isKindOfClass:NSNumber.class] ||
     strcmp([static_cast<NSNumber*>(value) objCType],@encode(BOOL))==0)
    fail([label stringByAppendingString:@" is not integer"]);
  const long long signedValue = [static_cast<NSNumber*>(value) longLongValue];
  if(signedValue<0)
    fail([label stringByAppendingString:@" is negative"]);
  return static_cast<uint64_t>(signedValue);
  }

void requireStrings(NSArray* actual, NSArray<NSString*>* expected,
                    NSString* label) {
  if(![actual isEqualToArray:expected])
    fail([label stringByAppendingString:@" order differs"]);
  }

NSString* documentsPath(NSString* leaf) {
  NSURL* documents = [NSFileManager.defaultManager URLsForDirectory:
      NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
  if(documents==nil)
    fail(@"Documents directory unavailable");
  return [[documents URLByAppendingPathComponent:leaf] path];
  }

void writeResult() {
  NSURL* fixtureUrl = [NSBundle.mainBundle
      URLForResource:@"p21e2a-remaining-material-census-v1"
      withExtension:@"json" subdirectory:@"fixtures"];
  if(fixtureUrl==nil)
    fail(@"fixture missing");
  NSData* raw = [NSData dataWithContentsOfURL:fixtureUrl];
  if(raw==nil)
    fail(@"fixture unreadable");
  NSError* error = nil;
  id decoded = [NSJSONSerialization JSONObjectWithData:raw options:0 error:&error];
  if(error!=nil || ![decoded isKindOfClass:NSDictionary.class])
    fail(@"fixture JSON invalid");
  NSDictionary* fixture = static_cast<NSDictionary*>(decoded);
  NSSet* keys = [NSSet setWithArray:@[
      @"schemaVersion",@"materials",@"kinds",@"modes",@"expectedCells",
      @"expectedTotals",@"expectedGlobalTotal",@"expectedIgnored",
      @"expectedInvalid",@"expectedOverflow"]];
  if(![[NSSet setWithArray:fixture.allKeys] isEqualToSet:keys] ||
     exactUint(fixture[@"schemaVersion"],@"schemaVersion")!=1u)
    fail(@"fixture schema differs");
  requireStrings(exactArray(fixture,@"materials",5),
                 @[@"water",@"ghost",@"multiply",@"multiply2",@"transparent"],
                 @"materials");
  requireStrings(exactArray(fixture,@"kinds",7),
                 @[@"landscape",@"static",@"movable",@"animated",@"particle",
                   @"morph",@"unsupported"],@"kinds");
  requireStrings(exactArray(fixture,@"modes",4),
                 @[@"none",@"frame-only",@"uv-only",@"frame-and-uv"],
                 @"modes");
  NSArray* expectedCells = exactArray(fixture,@"expectedCells",140);
  NSArray* expectedTotals = exactArray(fixture,@"expectedTotals",5);

  IOSRemainingMaterialCensus census;
  uint64_t recorded = 0;
  for(std::size_t material=0; material<Materials.size(); ++material)
    for(std::size_t kind=0; kind<Kinds.size(); ++kind)
      for(std::size_t mode=0; mode<Modes.size(); ++mode) {
        if(iosRecordRemainingMaterialCensus(
               Kinds[kind],Materials[material],Modes[mode],census)!=
           IOSRemainingMaterialCensusResult::Recorded)
          fail(@"valid cell was not recorded");
        const std::size_t index =
            (material*Kinds.size()+kind)*Modes.size()+mode;
        if(census.cells[index]!=exactUint(expectedCells[index],@"expectedCell"))
          fail(@"cell differs");
        ++recorded;
        }
  if(recorded!=140u)
    fail(@"recorded count differs");
  std::array<uint64_t,IOSRemainingMaterialCount> rawTotals{};
  for(std::size_t material=0; material<rawTotals.size(); ++material) {
    rawTotals[material] = exactUint(expectedTotals[material],@"expectedTotal");
    if(census.totals[material]!=rawTotals[material])
      fail(@"material total differs");
    }
  if(census.globalTotal!=exactUint(
       fixture[@"expectedGlobalTotal"],@"expectedGlobalTotal") ||
     !iosFinalizeRemainingMaterialCensus(census,rawTotals))
    fail(@"global/final conservation differs");
  auto crossMaterial = census;
  --crossMaterial.cells[0];
  ++crossMaterial.cells[IOSRemainingMaterialKindCount*
                        IOSRemainingMaterialModeCount];
  --crossMaterial.totals[0];
  ++crossMaterial.totals[1];
  if(iosFinalizeRemainingMaterialCensus(crossMaterial,rawTotals))
    fail(@"cross-material mismatch was accepted");

  uint64_t ignored = 0;
  for(const auto value:{std::optional<Material::AlphaFunc>{},
                        std::optional<Material::AlphaFunc>{Material::Solid},
                        std::optional<Material::AlphaFunc>{Material::AlphaTest},
                        std::optional<Material::AlphaFunc>{Material::AdditiveLight}}) {
    auto next = census;
    if(iosRecordRemainingMaterialCensus(
           IOSSceneSourceKind::Static,value,
           IOSSceneTextureAnimationMode::None,next)!=
           IOSRemainingMaterialCensusResult::Ignored || next!=census)
      fail(@"ignored case differs");
    ++ignored;
    }
  if(ignored!=exactUint(fixture[@"expectedIgnored"],@"expectedIgnored"))
    fail(@"ignored count differs");

  uint64_t invalid = 0;
  for(const auto result:{
      iosRecordRemainingMaterialCensus(
          static_cast<IOSSceneSourceKind>(255u),Material::Water,
          IOSSceneTextureAnimationMode::None,census),
      iosRecordRemainingMaterialCensus(
          IOSSceneSourceKind::Static,Material::Water,
          static_cast<IOSSceneTextureAnimationMode>(255u),census),
      iosRecordRemainingMaterialCensus(
          IOSSceneSourceKind::Static,static_cast<Material::AlphaFunc>(255u),
          IOSSceneTextureAnimationMode::None,census),
      iosRecordRemainingMaterialCensus(
          static_cast<IOSSceneSourceKind>(255u),std::nullopt,
          IOSSceneTextureAnimationMode::None,census)}) {
    if(result!=IOSRemainingMaterialCensusResult::Invalid)
      fail(@"invalid case differed");
    ++invalid;
    }
  if(invalid!=exactUint(fixture[@"expectedInvalid"],@"expectedInvalid"))
    fail(@"invalid count differs");

  uint64_t overflow = 0;
  for(int domain=0; domain<3; ++domain) {
    IOSRemainingMaterialCensus full;
    if(domain==0) full.cells[0] = std::numeric_limits<uint64_t>::max();
    if(domain==1) full.totals[0] = std::numeric_limits<uint64_t>::max();
    if(domain==2) full.globalTotal = std::numeric_limits<uint64_t>::max();
    const auto before = full;
    if(iosRecordRemainingMaterialCensus(
           IOSSceneSourceKind::Landscape,Material::Water,
           IOSSceneTextureAnimationMode::None,full)!=
           IOSRemainingMaterialCensusResult::Overflow || full!=before)
      fail(@"overflow was not atomic");
    ++overflow;
    }
  if(overflow!=exactUint(fixture[@"expectedOverflow"],@"expectedOverflow"))
    fail(@"overflow count differs");

  const auto candidate = prepareIOSRemainingMaterialCensusDiagnosticCandidate(
      census,rawTotals,1u,1u);
  if(!iosRemainingMaterialCensusCandidateAcceptsCommit(
       candidate,true,true,1u,1u,1u,1u))
    fail(@"accepted candidate was rejected");

  NSMutableString* output = [NSMutableString string];
  [output appendFormat:
      @"RendererIOS remaining material census: v=1 b=%s g=1 s=1 n=5,7,4 r=140 t=140\n",
      OPENGOTHIC_RENDERER_IOS_BUILD_SHA];
  for(std::size_t material=0; material<Materials.size(); ++material) {
    [output appendFormat:
        @"RendererIOS remaining material census material: v=1 b=%s g=1 s=1 m=%s r=28 t=28\n",
        OPENGOTHIC_RENDERER_IOS_BUILD_SHA,MaterialNames[material]];
    for(std::size_t kind=0; kind<Kinds.size(); ++kind)
      [output appendFormat:
          @"RendererIOS remaining material census row: v=1 b=%s g=1 s=1 m=%s k=%s c=1,1,1,1\n",
          OPENGOTHIC_RENDERER_IOS_BUILD_SHA,MaterialNames[material],
          KindNames[kind]];
    }
  NSError* writeError = nil;
  if(![output writeToFile:documentsPath(@"remaining-material-census.log")
                  atomically:YES encoding:NSUTF8StringEncoding error:&writeError])
    fail(@"cannot write census log");
  NSString* terminal = [NSString stringWithFormat:
      @"RemainingMaterialCensusAdapter terminal: v=1 b=%s g=1 s=1 result=PASS\n",
      OPENGOTHIC_RENDERER_IOS_BUILD_SHA];
  if(![terminal writeToFile:documentsPath(@"result.txt") atomically:YES
                   encoding:NSUTF8StringEncoding error:&writeError])
    fail(@"cannot write terminal result");
  }

}

void publishResult() {
  @try {
    writeResult();
  }
  @catch(NSException* exception) {
    NSString* terminal = [NSString stringWithFormat:
        @"RemainingMaterialCensusAdapter FAIL: %@\n",exception.reason];
    [terminal writeToFile:documentsPath(@"result.txt") atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
  }
  }

@interface RemainingMaterialCensusSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow* window;
@end

@implementation RemainingMaterialCensusSceneDelegate
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
    options:(UISceneConnectionOptions*)connectionOptions {
  (void)session;
  (void)connectionOptions;
  if(![scene isKindOfClass:UIWindowScene.class])
    return;
  self.window = [[UIWindow alloc]
      initWithWindowScene:static_cast<UIWindowScene*>(scene)];
  self.window.rootViewController = [[UIViewController alloc] init];
  self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
  [self.window makeKeyAndVisible];
  publishResult();
  }
@end

@interface RemainingMaterialCensusDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation RemainingMaterialCensusDelegate
- (UISceneConfiguration*)application:(UIApplication*)application
    configurationForConnectingSceneSession:(UISceneSession*)session
    options:(UISceneConnectionOptions*)connectionOptions {
  (void)application;
  (void)connectionOptions;
  UISceneConfiguration* configuration = [[UISceneConfiguration alloc]
      initWithName:@"Default Configuration" sessionRole:session.role];
  configuration.delegateClass = RemainingMaterialCensusSceneDelegate.class;
  return configuration;
  }

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)options {
  (void)application;
  (void)options;
  return YES;
  }
@end

int main(int argc, char** argv) {
  @autoreleasepool {
    return UIApplicationMain(argc,argv,nil,
        NSStringFromClass(RemainingMaterialCensusDelegate.class));
  }
}
