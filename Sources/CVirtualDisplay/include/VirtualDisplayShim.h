#ifndef VirtualDisplayShim_h
#define VirtualDisplayShim_h

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

/// Creates a virtual display and returns an owning handle, or NULL when the private API
/// is missing or creation fails. `displayID` receives its CGDirectDisplayID.
void *_Nullable VDVirtualDisplayCreate(const char *_Nonnull name,
                                       uint32_t vendorID, uint32_t productID, uint32_t serial,
                                       uint32_t maxWidth, uint32_t maxHeight,
                                       double widthMM, double heightMM,
                                       uint32_t width, uint32_t height, double refreshRate,
                                       CGDirectDisplayID *_Nonnull displayID);

/// Switches an existing display to a 1x mode of the given size.
bool VDVirtualDisplayApplyMode(void *_Nonnull handle,
                               uint32_t width, uint32_t height, double refreshRate);

/// Gives up ownership; the display disappears once released.
void VDVirtualDisplayRelease(void *_Nonnull handle);

#endif
