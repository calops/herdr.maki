-- Herdr integration for maki — one entry file, the work in lua/herdr/.
--
--   herdr.cli        environment gate and Herdr CLI transport, shared
--   herdr.link       herdr-link/1 cross-agent gateway (`herdr_link`, /herdr)
--   herdr.lifecycle  lifecycle state reporting (idle / working / blocked)
--   herdr.util       two tiny helpers
--
-- Every module checks the environment gate itself and returns early, so
-- requiring this package outside a Herdr-managed pane registers nothing.

require("herdr.link")
require("herdr.lifecycle")
