# SPDX-License-Identifier: MIT
from gravity_firmware.core import FWFile


def firmware_bytes(files):
    """Check the package interface before applying the ported byte assertions."""
    result = {}
    for name, firmware in files:
        assert isinstance(firmware, FWFile)
        assert name == firmware.name
        assert name not in result
        result[name] = firmware.data
    return result
