# Radix scan backend

This directory contains the non-UI `RadixCore` sources vendored from:

- Repository: https://github.com/colinvkim/Radix
- Revision: `d26a57b9aec4f9887c1832784ce249fb9e0559e3`
- License: MIT (`LICENSE.txt`)

ClearDisk-specific integration is exposed through `ClearDiskBridge.swift`. Keeping the
bridge separate makes upstream refreshes easier and prevents the disk scanner from
depending on ClearDisk's developer-cache model.
