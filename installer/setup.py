#!/usr/bin/env python

from distutils.core import setup

setup(name='gravity_firmware',
      version='0.1',
      description='Firmware tools for the MacBook Neo installer (derived from the Asahi Linux installer)',
      author='Hector Martin',
      author_email='marcan@marcan.st',
      packages=['gravity_firmware'],
      entry_points={"console_scripts": ["gravity-fwextract = gravity_firmware.update:main"]}
     )
