#include <stdint.h>
#include <string.h>
#include <string>

#include <fuzzer/FuzzedDataProvider.h>
#include "yyjson.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    FuzzedDataProvider provider(data, size);
    std::string str = provider.ConsumeRandomLengthString(1000);
    const char *cstr = str.c_str();
    yyjson_doc *doc = yyjson_read(cstr, strlen(cstr), 0);
    yyjson_doc_free(doc);
    return 0;
}
