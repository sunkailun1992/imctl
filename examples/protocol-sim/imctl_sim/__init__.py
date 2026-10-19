"""imctl protocol simulator: a mock controller that speaks the IM Control
Protocol over MQTT, and a driver that plays the business side.

Both follow docs/protocol/im-control-protocol.md; the mock is for integration
work without a Mac or a WeCom account and is never a substitute for live
acceptance against the real client.
"""

__version__ = "0.1.0"
