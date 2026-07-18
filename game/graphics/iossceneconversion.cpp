#include "iossceneconversion.h"

#include <Tempest/Matrix4x4>

#include <cstddef>

IOSMatrix4x4 IOSSceneConversion::matrix(
    const Tempest::Matrix4x4& source) noexcept {
  IOSMatrix4x4 result;
  for(std::size_t row=0; row<4u; ++row) {
    for(std::size_t column=0; column<4u; ++column)
      result.set(row,column,source.at(int(column),int(row)));
    }
  return result;
  }
