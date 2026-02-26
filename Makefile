# See LICENSE for licensing information.

PROJECT = gen_http
PROJECT_DESCRIPTION = Erlang native HTTP client with support for HTTP/1 and HTTP/2.
PROJECT_VERSION = 0.1.0

# Options.

ERLC_OPTS = +debug_info

# Dependencies.

LOCAL_DEPS = crypto ssl

# Standard targets.

ifndef ERLANG_MK_FILENAME
ERLANG_MK_VERSION = 2024.07.02

erlang.mk:
	curl -o $@ https://raw.githubusercontent.com/ninenines/erlang.mk/v$(ERLANG_MK_VERSION)/erlang.mk
endif

include $(if $(ERLANG_MK_FILENAME),$(ERLANG_MK_FILENAME),erlang.mk)
