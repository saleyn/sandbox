defmodule AirWeb.PageController do
  use AirWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
