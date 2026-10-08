compile: mix.lock
	mix $@


mix.lock: mix.exs
	mix deps.get

run:
	iex -S mix phx.server
