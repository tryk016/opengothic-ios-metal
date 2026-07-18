#pragma once

#include "iosscenesnapshot.h"

namespace Tempest {
class Matrix4x4;
}

namespace IOSSceneConversion {

IOSMatrix4x4 matrix(const Tempest::Matrix4x4& source) noexcept;

}
