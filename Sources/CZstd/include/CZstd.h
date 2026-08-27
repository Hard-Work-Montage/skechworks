// Sketchyworks's window onto zstd.
//
// Figma compresses a .fig's document chunk with it, and macOS has no zstd of
// its own — Compression offers zlib, lzma, lz4, brotli and lzfse and stops — so
// the decompressor travels with us.
//
// Two prototypes rather than zstd.h itself. The real header lives beside the
// sources where they can reach it, and exporting the whole of it would put a
// compression library's entire surface into this app's namespace to call two
// functions. These match upstream exactly; a mismatch would be a link error,
// not a silent one.
#ifndef SKETCHYWORKS_CZSTD_H
#define SKETCHYWORKS_CZSTD_H

#include <stddef.h>

/// Decompresses one frame. Returns the size written, or an error code that
/// reads as an enormous unsigned value.
size_t ZSTD_decompress(void *dst, size_t dstCapacity, const void *src, size_t srcSize);

/// What the frame says it decompresses to. ULLONG_MAX means it didn't say;
/// ULLONG_MAX - 1 means the frame is unreadable.
unsigned long long ZSTD_getFrameContentSize(const void *src, size_t srcSize);

#endif
