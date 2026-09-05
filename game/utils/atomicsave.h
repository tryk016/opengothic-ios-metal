#pragma once

#include <Tempest/File>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <string_view>

// The load/save worker serializes requests; a leftover temporary file from an
// interrupted save is replaced by the next attempt, never loaded as a slot.
template<class Write>
void writeSaveAtomically(std::string_view slot, Write&& write) {
  const std::filesystem::path destination(std::u8string(slot.begin(),slot.end()));
  auto temporary = destination;
  temporary += ".tmp";
  try {
    {
    Tempest::WFile file(temporary.u16string());
    write(file);
    if(!file.flush())
      throw std::runtime_error("unable to flush save-game file");
    }
    std::filesystem::rename(temporary,destination);
    }
  catch(...) {
    std::error_code ignored;
    std::filesystem::remove(temporary,ignored);
    throw;
    }
  }
