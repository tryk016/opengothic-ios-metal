#include "game/serialize.h"
#include "utils/atomicsave.h"

#include <Tempest/MemReader>
#include <Tempest/MemWriter>
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <iterator>

namespace {
size_t liveZipAllocations = 0;
void* zipAllocate(size_t size) {
  void* result = std::malloc(size);
  if(result!=nullptr)
    ++liveZipAllocations;
  return result;
  }
void zipFree(void* pointer) {
  if(pointer!=nullptr)
    --liveZipAllocations;
  std::free(pointer);
  }
void* zipReallocate(void* pointer, size_t size) {
  if(size==0) {
    zipFree(pointer);
    return nullptr;
    }
  if(pointer==nullptr)
    return zipAllocate(size);
  return std::realloc(pointer,size);
  }
}

// Count actual miniz allocations so repeated menu-style reads verify cleanup.
#undef MZ_MALLOC
#undef MZ_FREE
#undef MZ_REALLOC
#define MZ_MALLOC(size) zipAllocate(size)
#define MZ_FREE(pointer) zipFree(pointer)
#define MZ_REALLOC(pointer,size) zipReallocate(pointer,size)
#include <miniz.c>

namespace {
class FailingOutput final : public Tempest::ODevice {
  public:
    enum Failure { Entry, Directory };
    explicit FailingOutput(Failure failure):failure(failure) {}
    size_t write(const void* data,size_t size) override {
      const auto* bytes = static_cast<const unsigned char*>(data);
      if(failure==Entry ||
         (size>=4 && bytes[0]=='P' && bytes[1]=='K' && bytes[2]==1 && bytes[3]==2))
        return 0;
      return size;
      }
    bool flush() override { return true; }
  private:
    Failure failure;
  };

template<class Operation>
void expectFailure(Operation operation) {
  bool failed = false;
  try { operation(); }
  catch(const std::runtime_error&) { failed = true; }
  assert(failed);
  }

std::string contents(const std::filesystem::path& file) {
  std::ifstream input(file,std::ios::binary);
  return {std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>()};
  }
}

int main(int argc,char** argv) {
  assert(argc==2);
  std::vector<uint8_t> archive;
  {
  Tempest::MemWriter output(archive);
  Serialize writer(output);
  writer.setEntry("header");
  writer.write(uint32_t(123));
  writer.finish();
  }
  assert(liveZipAllocations==0);

  for(int i=0;i<100;++i) {
    {
    Tempest::MemReader input(archive);
    Serialize reader(input);
    assert(reader.setEntry("header"));
    uint32_t value = 0;
    reader.read(value);
    assert(value==123);
    }
    assert(liveZipAllocations==0);
    }

  for(auto failure:{FailingOutput::Entry,FailingOutput::Directory}) {
    expectFailure([&] {
      FailingOutput output(failure);
      Serialize writer(output);
      writer.setEntry("header");
      writer.write(uint32_t(123));
      writer.finish();
      });
    assert(liveZipAllocations==0);
    }

  auto damaged = archive;
  // The four-byte uncompressed entry starts after the ZIP local header/name.
  damaged[30+std::string_view("header").size()] ^= 1;
  expectFailure([&] {
    Tempest::MemReader input(damaged);
    Serialize reader(input);
    reader.setEntry("header");
    });
  assert(liveZipAllocations==0);

  const auto slot = std::filesystem::path(argv[1])/"save.sav";
  { std::ofstream old(slot); old << "previous save"; }
  expectFailure([&] {
    writeSaveAtomically(slot.string(),[&](Tempest::ODevice& output) {
      output.write("partial",7);
      assert(contents(slot)=="previous save");
      throw std::runtime_error("interrupted save");
      });
    });
  assert(contents(slot)=="previous save");
  assert(!std::filesystem::exists(slot.string()+".tmp"));
  writeSaveAtomically(slot.string(),[&](Tempest::ODevice& output) {
    Serialize writer(output);
    writer.setEntry("header");
    writer.write(uint32_t(123));
    writer.finish();
    assert(contents(slot)=="previous save");
    });
  const auto saved = contents(slot);
  assert(std::vector<uint8_t>(saved.begin(),saved.end())==archive);
  assert(!std::filesystem::exists(slot.string()+".tmp"));
  assert(liveZipAllocations==0);
  }
