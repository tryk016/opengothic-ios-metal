#include "graphics/iossceneconversion.h"

#include <Tempest/Matrix4x4>

#include <array>
#include <cassert>
#include <cstddef>

int main() {
  Tempest::Matrix4x4 source;
  for(std::size_t row=0; row<4u; ++row) {
    for(std::size_t column=0; column<4u; ++column) {
      source.set(int(column),int(row),float(row*4u+column+1u));
      }
    }

  const auto converted = IOSSceneConversion::matrix(source);
  const std::array<float,16> expectedColumnMajor = {
    1.f,5.f,9.f,13.f,
    2.f,6.f,10.f,14.f,
    3.f,7.f,11.f,15.f,
    4.f,8.f,12.f,16.f,
    };
  assert(converted.elements==expectedColumnMajor);
  assert(converted.at(0u,3u)==4.f);
  assert(converted.at(3u,0u)==13.f);

  source = Tempest::Matrix4x4();
  source.set(0,0,1.f);
  source.set(1,1,1.f);
  source.set(2,2,1.f);
  source.set(3,3,1.f);
  source.set(3,0,10.f);
  source.set(3,1,20.f);
  source.set(3,2,30.f);
  const auto translation = IOSSceneConversion::matrix(source);
  assert(translation.at(0u,3u)==10.f);
  assert(translation.at(1u,3u)==20.f);
  assert(translation.at(2u,3u)==30.f);
  assert(translation.elements[12u]==10.f);
  assert(translation.elements[13u]==20.f);
  assert(translation.elements[14u]==30.f);
  return 0;
  }
