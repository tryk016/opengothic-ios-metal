#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "game/graphics/iosadditivesourcecensus.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <optional>
#include <string>

namespace {

constexpr std::array<const char*,7> FixtureKindNames = {
  "landscape", "static", "movable", "animated", "particle", "morph",
  "unsupported",
  };
constexpr std::array<const char*,7> LogKindNames = {
  "Landscape", "Static", "Movable", "Animated", "Particle", "Morph",
  "Unsupported",
  };
constexpr std::array<const char*,4> ModeNames = {
  "none", "frame-only", "uv-only", "frame-and-uv",
  };

bool fail(NSString* message) {
  const char* text = message.UTF8String;
  std::fprintf(stderr,"AdditiveCensusAdapter FAIL: %s\n",
               text!=nullptr ? text : "unknown error");
  std::fflush(stderr);
  return false;
  }

bool hasExactKeys(NSDictionary* dictionary, NSArray<NSString*>* keys) {
  if(dictionary.count!=keys.count)
    return false;
  NSSet* actual = [NSSet setWithArray:dictionary.allKeys];
  return [actual isEqualToSet:[NSSet setWithArray:keys]];
  }

bool isCanonicalUnsigned(NSNumber* number) {
  if(![number isKindOfClass:NSNumber.class] ||
     CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID())
    return false;
  const char* type = number.objCType;
  if(type==nullptr)
    return false;
  const std::string types(type);
  if(types!="c" && types!="s" && types!="i" && types!="l" && types!="q" &&
     types!="C" && types!="S" && types!="I" && types!="L" && types!="Q")
    return false;
  return number.longLongValue>=0;
  }

class StrictJSONScanner final {
  public:
    explicit StrictJSONScanner(NSString* text) : text(text) {}

    bool parse() {
      skipWhitespace();
      if(!parseValue())
        return false;
      skipWhitespace();
      return index==text.length;
      }

  private:
    void skipWhitespace() {
      while(index<text.length) {
        const unichar value = [text characterAtIndex:index];
        if(value!=' ' && value!='\t' && value!='\n' && value!='\r')
          return;
        ++index;
        }
      }

    bool consume(unichar value) {
      if(index>=text.length || [text characterAtIndex:index]!=value)
        return false;
      ++index;
      return true;
      }

    bool consumeLiteral(NSString* literal) {
      const NSRange range = NSMakeRange(index,literal.length);
      if(NSMaxRange(range)>text.length ||
         ![[text substringWithRange:range] isEqualToString:literal])
        return false;
      index += literal.length;
      return true;
      }

    static int hexValue(unichar value) {
      if(value>='0' && value<='9')
        return static_cast<int>(value-'0');
      if(value>='a' && value<='f')
        return 10+static_cast<int>(value-'a');
      if(value>='A' && value<='F')
        return 10+static_cast<int>(value-'A');
      return -1;
      }

    NSString* parseString() {
      if(!consume('"'))
        return nil;
      NSMutableString* value = [NSMutableString string];
      while(index<text.length) {
        unichar current = [text characterAtIndex:index++];
        if(current=='"')
          return [value copy];
        if(current<0x20u)
          return nil;
        if(current!='\\') {
          [value appendFormat:@"%C",current];
          continue;
          }
        if(index>=text.length)
          return nil;
        current = [text characterAtIndex:index++];
        switch(current) {
          case '"': [value appendString:@"\""]; break;
          case '\\': [value appendString:@"\\"]; break;
          case '/': [value appendString:@"/"]; break;
          case 'b': [value appendString:@"\b"]; break;
          case 'f': [value appendString:@"\f"]; break;
          case 'n': [value appendString:@"\n"]; break;
          case 'r': [value appendString:@"\r"]; break;
          case 't': [value appendString:@"\t"]; break;
          case 'u': {
            if(index+4u>text.length)
              return nil;
            unsigned code = 0;
            for(unsigned digit=0; digit<4u; ++digit) {
              const int parsed = hexValue([text characterAtIndex:index++]);
              if(parsed<0)
                return nil;
              code = code*16u+static_cast<unsigned>(parsed);
              }
            [value appendFormat:@"%C",static_cast<unichar>(code)];
            break;
            }
          default:
            return nil;
          }
        }
      return nil;
      }

    bool parseNumber() {
      if(index<text.length && [text characterAtIndex:index]=='-')
        ++index;
      if(index>=text.length)
        return false;
      if([text characterAtIndex:index]=='0') {
        ++index;
        if(index<text.length) {
          const unichar next = [text characterAtIndex:index];
          if(next>='0' && next<='9')
            return false;
          }
        }
      else {
        const unichar first = [text characterAtIndex:index];
        if(first<'1' || first>'9')
          return false;
        while(index<text.length) {
          const unichar digit = [text characterAtIndex:index];
          if(digit<'0' || digit>'9')
            break;
          ++index;
          }
        }
      if(index<text.length && [text characterAtIndex:index]=='.') {
        ++index;
        const NSUInteger firstFraction = index;
        while(index<text.length) {
          const unichar digit = [text characterAtIndex:index];
          if(digit<'0' || digit>'9')
            break;
          ++index;
          }
        if(index==firstFraction)
          return false;
        }
      if(index<text.length &&
         ([text characterAtIndex:index]=='e' ||
          [text characterAtIndex:index]=='E')) {
        ++index;
        if(index<text.length &&
           ([text characterAtIndex:index]=='+' ||
            [text characterAtIndex:index]=='-'))
          ++index;
        const NSUInteger firstExponent = index;
        while(index<text.length) {
          const unichar digit = [text characterAtIndex:index];
          if(digit<'0' || digit>'9')
            break;
          ++index;
          }
        if(index==firstExponent)
          return false;
        }
      return true;
      }

    bool parseArray() {
      if(!consume('['))
        return false;
      skipWhitespace();
      if(consume(']'))
        return true;
      for(;;) {
        skipWhitespace();
        if(!parseValue())
          return false;
        skipWhitespace();
        if(consume(']'))
          return true;
        if(!consume(','))
          return false;
        }
      }

    bool parseObject() {
      if(!consume('{'))
        return false;
      NSMutableSet<NSString*>* keys = [NSMutableSet set];
      skipWhitespace();
      if(consume('}'))
        return true;
      for(;;) {
        skipWhitespace();
        NSString* key = parseString();
        if(key==nil || [keys containsObject:key])
          return false;
        [keys addObject:key];
        skipWhitespace();
        if(!consume(':'))
          return false;
        skipWhitespace();
        if(!parseValue())
          return false;
        skipWhitespace();
        if(consume('}'))
          return true;
        if(!consume(','))
          return false;
        }
      }

    bool parseValue() {
      if(index>=text.length)
        return false;
      switch([text characterAtIndex:index]) {
        case '{': return parseObject();
        case '[': return parseArray();
        case '"': return parseString()!=nil;
        case 't': return consumeLiteral(@"true");
        case 'f': return consumeLiteral(@"false");
        case 'n': return consumeLiteral(@"null");
        default: return parseNumber();
        }
      }

    NSString* text;
    NSUInteger index = 0;
  };

NSDictionary* loadJSONObject(NSString* directory, NSString* filename) {
  NSString* path = [NSBundle.mainBundle.resourcePath
      stringByAppendingPathComponent:
          [directory stringByAppendingPathComponent:filename]];
  NSData* data = [NSData dataWithContentsOfFile:path];
  if(data==nil)
    return nil;
  NSString* source = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
  if(source==nil || !StrictJSONScanner(source).parse())
    return nil;
  NSError* error = nil;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if(error!=nil || ![value isKindOfClass:NSDictionary.class])
    return nil;
  return value;
  }

bool validateStrictJSONScannerMutations() {
  return StrictJSONScanner(@"{\"root\":{\"value\":1},\"array\":[null,true,false]}").parse() &&
         !StrictJSONScanner(@"{\"schemaVersion\":1,\"schemaVersion\":1}").parse() &&
         !StrictJSONScanner(@"{\"schemaVersion\":1,\"schema\\u0056ersion\":1}").parse() &&
         !StrictJSONScanner(@"{\"root\":{\"value\":1,\"value\":2}}").parse();
  }

std::optional<IOSSceneSourceKind> parseKind(NSString* name) {
  for(std::size_t i=0; i<FixtureKindNames.size(); ++i)
    if([name isEqualToString:
         [NSString stringWithUTF8String:FixtureKindNames[i]]])
      return static_cast<IOSSceneSourceKind>(i);
  if([name isEqualToString:@"unknown"])
    return static_cast<IOSSceneSourceKind>(255u);
  return std::nullopt;
  }

std::optional<IOSSceneTextureAnimationMode> parseMode(NSString* name) {
  for(std::size_t i=0; i<ModeNames.size(); ++i)
    if([name isEqualToString:[NSString stringWithUTF8String:ModeNames[i]]])
      return static_cast<IOSSceneTextureAnimationMode>(i);
  if([name isEqualToString:@"unknown"])
    return static_cast<IOSSceneTextureAnimationMode>(255u);
  return std::nullopt;
  }

bool parseAlpha(id value, std::optional<Material::AlphaFunc>& alpha) {
  if(value==NSNull.null) {
    alpha = std::nullopt;
    return true;
    }
  if(![value isKindOfClass:NSString.class])
    return false;
  NSString* name = value;
  if([name isEqualToString:@"solid"])
    alpha = Material::Solid;
  else if([name isEqualToString:@"additive-light"])
    alpha = Material::AdditiveLight;
  else if([name isEqualToString:@"unknown"])
    alpha = static_cast<Material::AlphaFunc>(255u);
  else
    return false;
  return true;
  }

std::optional<IOSAdditiveCensusResult> parseResult(NSString* name) {
  if([name isEqualToString:@"ignored"])
    return IOSAdditiveCensusResult::Ignored;
  if([name isEqualToString:@"recorded"])
    return IOSAdditiveCensusResult::Recorded;
  if([name isEqualToString:@"invalid"])
    return IOSAdditiveCensusResult::Invalid;
  if([name isEqualToString:@"overflow"])
    return IOSAdditiveCensusResult::Overflow;
  return std::nullopt;
  }

bool parseRecord(NSDictionary* record,
                 IOSSceneSourceKind& kind,
                 IOSSceneTextureAnimationMode& mode,
                 std::optional<Material::AlphaFunc>& alpha,
                 IOSAdditiveCensusResult& expected) {
  if(![record isKindOfClass:NSDictionary.class] ||
     !hasExactKeys(record,@[@"kind",@"mode",@"alpha",@"result"]) ||
     ![record[@"kind"] isKindOfClass:NSString.class] ||
     ![record[@"mode"] isKindOfClass:NSString.class] ||
     ![record[@"result"] isKindOfClass:NSString.class])
    return false;
  const auto parsedKind = parseKind(record[@"kind"]);
  const auto parsedMode = parseMode(record[@"mode"]);
  const auto parsedResult = parseResult(record[@"result"]);
  if(!parsedKind || !parsedMode || !parsedResult ||
     !parseAlpha(record[@"alpha"],alpha))
    return false;
  kind = *parsedKind;
  mode = *parsedMode;
  expected = *parsedResult;
  return true;
  }

bool validateSpec(NSDictionary* spec, NSString* __strong& fixtureName,
                  uint64_t& generation, uint64_t& sequence) {
  NSArray<NSString*>* keys = @[
    @"schemaVersion", @"fixture", @"scope", @"generation", @"sequence",
    @"orderedKinds", @"orderedModes", @"expectedCells", @"expectedTotal",
    @"expectedIgnored", @"expectedInvalid", @"expectedOverflow",
    ];
  if(!hasExactKeys(spec,keys) ||
     ![spec[@"fixture"] isKindOfClass:NSString.class] ||
     ![spec[@"scope"] isEqualToString:
         @"host-neutral-adapter,no-product-save-runtime"] ||
     ![spec[@"orderedKinds"] isKindOfClass:NSArray.class] ||
     ![spec[@"orderedModes"] isKindOfClass:NSArray.class] ||
     ![spec[@"expectedCells"] isKindOfClass:NSArray.class])
    return false;
  for(NSString* key in @[@"schemaVersion",@"generation",@"sequence",
                          @"expectedTotal",@"expectedIgnored",
                          @"expectedInvalid",@"expectedOverflow"])
    if(!isCanonicalUnsigned(spec[key]))
      return false;
  if([spec[@"schemaVersion"] unsignedLongLongValue]!=1u ||
     [spec[@"expectedTotal"] unsignedLongLongValue]!=28u ||
     [spec[@"expectedIgnored"] unsignedLongLongValue]!=2u ||
     [spec[@"expectedInvalid"] unsignedLongLongValue]!=3u ||
     [spec[@"expectedOverflow"] unsignedLongLongValue]!=2u)
    return false;
  if(![spec[@"orderedKinds"] isEqualToArray:
       @[@"landscape",@"static",@"movable",@"animated",@"particle",
         @"morph",@"unsupported"]] ||
     ![spec[@"orderedModes"] isEqualToArray:
       @[@"none",@"frame-only",@"uv-only",@"frame-and-uv"]])
    return false;
  NSArray* cells = spec[@"expectedCells"];
  if(cells.count!=28u)
    return false;
  for(NSNumber* cell in cells)
    if(!isCanonicalUnsigned(cell) || cell.unsignedLongLongValue!=1u)
      return false;
  generation = [spec[@"generation"] unsignedLongLongValue];
  sequence = [spec[@"sequence"] unsignedLongLongValue];
  if(generation==0 || sequence==0)
    return false;
  fixtureName = spec[@"fixture"];
  return [fixtureName isEqualToString:@"p21e1a-additive-census-v1.json"];
  }

bool validateAndRunFixture(NSDictionary* fixture,
                           IOSAdditiveSourceCensus& census) {
  if(!hasExactKeys(fixture,@[@"schemaVersion",@"records",@"negativeCases",
                              @"overflowCases"]) ||
     !isCanonicalUnsigned(fixture[@"schemaVersion"]) ||
     [fixture[@"schemaVersion"] unsignedLongLongValue]!=1u ||
     ![fixture[@"records"] isKindOfClass:NSArray.class] ||
     ![fixture[@"negativeCases"] isKindOfClass:NSArray.class] ||
     ![fixture[@"overflowCases"] isKindOfClass:NSArray.class])
    return false;

  NSArray* records = fixture[@"records"];
  if(records.count!=28u)
    return false;
  uint64_t ignored = 0;
  uint64_t invalid = 0;
  for(NSUInteger recordIndex=0; recordIndex<records.count; ++recordIndex) {
    NSDictionary* record = records[recordIndex];
    const NSUInteger kindIndex = recordIndex/4u;
    const NSUInteger modeIndex = recordIndex%4u;
    if(![record[@"kind"] isEqualToString:
          [NSString stringWithUTF8String:FixtureKindNames[kindIndex]]] ||
       ![record[@"mode"] isEqualToString:
          [NSString stringWithUTF8String:ModeNames[modeIndex]]] ||
       ![record[@"alpha"] isEqual:@"additive-light"] ||
       ![record[@"result"] isEqual:@"recorded"])
      return false;
    IOSSceneSourceKind kind;
    IOSSceneTextureAnimationMode mode;
    std::optional<Material::AlphaFunc> alpha;
    IOSAdditiveCensusResult expected;
    if(!parseRecord(record,kind,mode,alpha,expected))
      return false;
    const IOSAdditiveSourceCensus before = census;
    const auto actual = iosRecordAdditiveSourceCensus(kind,alpha,mode,census);
    if(actual!=expected)
      return false;
    if(actual!=IOSAdditiveCensusResult::Recorded || before.total+1u!=census.total)
      return false;
    }

  NSArray* negatives = fixture[@"negativeCases"];
  NSArray<NSDictionary*>* expectedNegatives = @[
    @{@"id":@"ignored-null-alpha",@"kind":@"static",@"mode":@"none",
      @"alpha":NSNull.null,@"result":@"ignored"},
    @{@"id":@"ignored-non-additive",@"kind":@"movable",
      @"mode":@"frame-only",@"alpha":@"solid",@"result":@"ignored"},
    @{@"id":@"invalid-kind",@"kind":@"unknown",@"mode":@"none",
      @"alpha":@"additive-light",@"result":@"invalid"},
    @{@"id":@"invalid-mode",@"kind":@"static",@"mode":@"unknown",
      @"alpha":@"additive-light",@"result":@"invalid"},
    @{@"id":@"invalid-alpha",@"kind":@"static",@"mode":@"none",
      @"alpha":@"unknown",@"result":@"invalid"},
    ];
  if(![negatives isEqualToArray:expectedNegatives])
    return false;
  for(NSDictionary* negative in negatives) {
    NSMutableDictionary* record = [negative mutableCopy];
    [record removeObjectForKey:@"id"];
    IOSSceneSourceKind kind;
    IOSSceneTextureAnimationMode mode;
    std::optional<Material::AlphaFunc> alpha;
    IOSAdditiveCensusResult expected;
    if(!parseRecord(record,kind,mode,alpha,expected))
      return false;
    const IOSAdditiveSourceCensus before = census;
    const auto actual = iosRecordAdditiveSourceCensus(kind,alpha,mode,census);
    if(actual!=expected || census!=before)
      return false;
    if(actual==IOSAdditiveCensusResult::Ignored)
      ++ignored;
    else if(actual==IOSAdditiveCensusResult::Invalid)
      ++invalid;
    else
      return false;
    }
  if(ignored!=2u || invalid!=3u || census.total!=28u ||
     !iosFinalizeAdditiveSourceCensus(census,28u))
    return false;
  for(uint64_t cell:census.cells)
    if(cell!=1u)
      return false;

  NSArray* overflows = fixture[@"overflowCases"];
  NSArray<NSDictionary*>* expectedOverflows = @[
    @{@"case":@"cell-max",@"kind":@"static",@"mode":@"none",
      @"alpha":@"additive-light",@"result":@"overflow"},
    @{@"case":@"total-max",@"kind":@"movable",@"mode":@"frame-only",
      @"alpha":@"additive-light",@"result":@"overflow"},
    ];
  if(![overflows isEqualToArray:expectedOverflows])
    return false;
  for(NSUInteger overflowIndex=0; overflowIndex<overflows.count;
      ++overflowIndex) {
    NSDictionary* record = overflows[overflowIndex];
    if(![record isKindOfClass:NSDictionary.class] ||
       !hasExactKeys(record,@[@"case",@"kind",@"mode",@"alpha",@"result"]) ||
       ![record[@"case"] isKindOfClass:NSString.class])
      return false;
    NSMutableDictionary* ordinary = [record mutableCopy];
    [ordinary removeObjectForKey:@"case"];
    IOSSceneSourceKind kind;
    IOSSceneTextureAnimationMode mode;
    std::optional<Material::AlphaFunc> alpha;
    IOSAdditiveCensusResult expected;
    if(!parseRecord(ordinary,kind,mode,alpha,expected) ||
       expected!=IOSAdditiveCensusResult::Overflow)
      return false;
    IOSAdditiveSourceCensus overflow;
    const std::size_t index = static_cast<std::size_t>(kind)*4u+
                              static_cast<std::size_t>(mode);
    NSString* expectedCase = overflowIndex==0u ? @"cell-max" : @"total-max";
    if(![record[@"case"] isEqualToString:expectedCase])
      return false;
    if([record[@"case"] isEqualToString:@"cell-max"])
      overflow.cells[index] = std::numeric_limits<uint64_t>::max();
    else if([record[@"case"] isEqualToString:@"total-max"])
      overflow.total = std::numeric_limits<uint64_t>::max();
    else
      return false;
    const IOSAdditiveSourceCensus before = overflow;
    if(iosRecordAdditiveSourceCensus(kind,alpha,mode,overflow)!=expected ||
       overflow.cells!=before.cells || overflow.total!=before.total)
      return false;
    }
  return true;
  }

NSMutableDictionary* mutableFixtureCopy(NSDictionary* fixture) {
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:fixture
                                                  options:0 error:&error];
  if(data==nil || error!=nil)
    return nil;
  id value = [NSJSONSerialization JSONObjectWithData:data
      options:NSJSONReadingMutableContainers error:&error];
  if(error!=nil || ![value isKindOfClass:NSMutableDictionary.class])
    return nil;
  return value;
  }

bool fixtureMutationIsRejected(NSDictionary* fixture) {
  IOSAdditiveSourceCensus ignored;
  return !validateAndRunFixture(fixture,ignored);
  }

bool validateFixtureMutations(NSDictionary* fixture) {
  NSMutableDictionary* swapped = mutableFixtureCopy(fixture);
  NSMutableArray* swappedNegatives = swapped[@"negativeCases"];
  [swappedNegatives exchangeObjectAtIndex:0 withObjectAtIndex:1];
  if(!fixtureMutationIsRejected(swapped))
    return false;

  NSMutableDictionary* duplicated = mutableFixtureCopy(fixture);
  NSMutableArray* duplicatedNegatives = duplicated[@"negativeCases"];
  duplicatedNegatives[1] = [duplicatedNegatives[0] mutableCopy];
  if(!fixtureMutationIsRejected(duplicated))
    return false;

  struct NegativeMutation final {
    NSUInteger index;
    __unsafe_unretained NSString* field;
    __unsafe_unretained id value;
    };
  const std::array<NegativeMutation,4> negativeMutations = {{
    {0u,@"alpha",@"solid"},
    {2u,@"kind",@"static"},
    {3u,@"mode",@"none"},
    {4u,@"alpha",@"additive-light"},
    }};
  for(const NegativeMutation& mutation:negativeMutations) {
    NSMutableDictionary* changed = mutableFixtureCopy(fixture);
    NSMutableArray* negatives = changed[@"negativeCases"];
    NSMutableDictionary* record = negatives[mutation.index];
    record[mutation.field] = mutation.value;
    if(!fixtureMutationIsRejected(changed))
      return false;
    }

  for(NSUInteger index=0; index<2u; ++index) {
    NSMutableDictionary* changed = mutableFixtureCopy(fixture);
    NSMutableArray* overflows = changed[@"overflowCases"];
    NSMutableDictionary* record = overflows[index];
    record[@"case"] = index==0u ? @"total-max" : @"cell-max";
    if(!fixtureMutationIsRejected(changed))
      return false;
    }
  return true;
  }

bool isLowercaseSHA40(NSString* value) {
  if(![value isKindOfClass:NSString.class] || value.length!=40u)
    return false;
  NSCharacterSet* invalid =
      [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]
          invertedSet];
  return [value rangeOfCharacterFromSet:invalid].location==NSNotFound;
  }

bool emitBlock(NSString* buildSHA, uint64_t generation, uint64_t sequence,
               const IOSAdditiveSourceCensus& census) {
  std::array<std::string,8> lines;
  char buffer[512];
  std::snprintf(buffer,sizeof(buffer),
      "RendererIOS additive source census: v=1 b=%s g=%llu s=%llu r=%llu t=%llu",
      buildSHA.UTF8String,
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence),
      static_cast<unsigned long long>(census.total),
      static_cast<unsigned long long>(census.total));
  lines[0] = buffer;
  for(std::size_t kind=0; kind<LogKindNames.size(); ++kind) {
    const std::size_t base = kind*ModeNames.size();
    std::snprintf(buffer,sizeof(buffer),
        "RendererIOS additive source census row: v=1 b=%s g=%llu s=%llu k=%s c=%llu,%llu,%llu,%llu",
        buildSHA.UTF8String,
        static_cast<unsigned long long>(generation),
        static_cast<unsigned long long>(sequence),LogKindNames[kind],
        static_cast<unsigned long long>(census.cells[base+0]),
        static_cast<unsigned long long>(census.cells[base+1]),
        static_cast<unsigned long long>(census.cells[base+2]),
        static_cast<unsigned long long>(census.cells[base+3]));
    lines[kind+1] = buffer;
    }
  const std::string sourceLine =
      "RendererIOS source census: v=2 b="+
      std::string(buildSHA.UTF8String)+" g="+std::to_string(generation)+
      " s="+std::to_string(sequence)+
      " k=4,4,4,4,4,4,4,0 m=0,0,0,0,0,0,0,28,0,0 a=14,14"
      " x=0,0,0 o=28,0,0,28,0,0";
  if(sourceLine.size()>254u)
    return false;
  for(const std::string& line:lines)
    if(line.size()>254u)
      return false;
  std::fprintf(stdout,"%s\n",sourceLine.c_str());
  for(const std::string& line:lines)
    std::fprintf(stdout,"%s\n",line.c_str());
  std::fflush(stdout);
  return true;
  }

bool runAdapter() {
  if(!validateStrictJSONScannerMutations())
    return fail(@"strict JSON duplicate-key self-test failed");
  NSDictionary* spec = loadJSONObject(@"specs",@"p21e1a-additive-census-v1.json");
  NSString* fixtureName = nil;
  uint64_t generation = 0;
  uint64_t sequence = 0;
  if(spec==nil || !validateSpec(spec,fixtureName,generation,sequence))
    return fail(@"strict spec validation failed");
  NSDictionary* fixture = loadJSONObject(@"fixtures",fixtureName);
  IOSAdditiveSourceCensus census;
  if(fixture==nil || !validateAndRunFixture(fixture,census))
    return fail(@"collector fixture validation failed");
  if(!validateFixtureMutations(fixture))
    return fail(@"fixture mutation rejection failed");
  NSString* buildSHA = [NSBundle.mainBundle objectForInfoDictionaryKey:
      @"OpenGothicBuildSHA"];
  if(!isLowercaseSHA40(buildSHA))
    return fail(@"build SHA is not canonical lowercase hex40");
  if(!emitBlock(buildSHA,generation,sequence,census))
    return fail(@"marker exceeds Tempest Log line budget");
  std::fprintf(stdout,
      "AdditiveCensusAdapter terminal: v=1 b=%s g=%llu s=%llu result=PASS\n",
      buildSHA.UTF8String,
      static_cast<unsigned long long>(generation),
      static_cast<unsigned long long>(sequence));
  std::fflush(stdout);
  return true;
  }

} // namespace

@interface AdditiveCensusAdapterSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow* window;
@end

@implementation AdditiveCensusAdapterSceneDelegate
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
    options:(UISceneConnectionOptions*)connectionOptions {
  (void)session;
  (void)connectionOptions;
  if(![scene isKindOfClass:UIWindowScene.class]) {
    fail(@"connected scene is not a UIWindowScene");
    std::_Exit(EXIT_FAILURE);
    }
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  UIViewController* controller = [UIViewController new];
  controller.view.backgroundColor = UIColor.blackColor;
  self.window.rootViewController = controller;
  [self.window makeKeyAndVisible];
  dispatch_async(dispatch_get_main_queue(), ^{
    if(std::getenv("ADDITIVE_CENSUS_HANG_MUTATION")!=nullptr)
      dispatch_semaphore_wait(dispatch_semaphore_create(0),
                              DISPATCH_TIME_FOREVER);
    if(std::getenv("ADDITIVE_CENSUS_CRASH_MUTATION")!=nullptr)
      __builtin_trap();
    const bool passed = runAdapter();
    std::fflush(nullptr);
    std::_Exit(passed ? EXIT_SUCCESS : EXIT_FAILURE);
  });
}
@end

@interface AdditiveCensusAdapterDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AdditiveCensusAdapterDelegate
- (UISceneConfiguration*)application:(UIApplication*)application
    configurationForConnectingSceneSession:(UISceneSession*)connectingSceneSession
    options:(UISceneConnectionOptions*)options {
  (void)application;
  (void)options;
  return [[UISceneConfiguration alloc]
      initWithName:@"Default Configuration"
      sessionRole:connectingSceneSession.role];
  }
@end

int main(int argc, char* argv[]) {
  std::setvbuf(stdout,nullptr,_IONBF,0);
  std::setvbuf(stderr,nullptr,_IONBF,0);
  @autoreleasepool {
    return UIApplicationMain(argc,argv,nil,
        NSStringFromClass(AdditiveCensusAdapterDelegate.class));
    }
  }
