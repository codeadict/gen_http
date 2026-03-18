-ifndef(GEN_HTTP_DOC_HRL).
-define(GEN_HTTP_DOC_HRL, true).

%% OTP 27+ native doc attributes, no-op on older releases.
-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-endif.
