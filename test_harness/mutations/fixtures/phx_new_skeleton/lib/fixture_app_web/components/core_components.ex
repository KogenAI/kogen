defmodule FixtureAppWeb.CoreComponents do
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  def flash(assigns) do
    ~H"""
    <div id={@id}><%= @msg %></div>
    """
  end

  def button(assigns) do
    ~H"""
    <button type={@type}>{render_slot(@inner_block)}</button>
    """
  end

  def input(assigns) do
    ~H"""
    <input type={@type} name={@name} value={@value} />
    """
  end

  def label(assigns) do
    ~H"""
    <label for={@for}>{render_slot(@inner_block)}</label>
    """
  end

  def error(assigns) do
    ~H"""
    <p class="error">{render_slot(@inner_block)}</p>
    """
  end

  def header(assigns) do
    ~H"""
    <header>{render_slot(@inner_block)}</header>
    """
  end

  def table(assigns) do
    ~H"""
    <table>{render_slot(@inner_block)}</table>
    """
  end

  def list(assigns) do
    ~H"""
    <ul>{render_slot(@inner_block)}</ul>
    """
  end

  def back(assigns) do
    ~H"""
    <a href={@navigate}>{render_slot(@inner_block)}</a>
    """
  end

  def icon(assigns) do
    ~H"""
    <span class={"hero-#{@name}"}></span>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", fn _ -> to_string(v) end)
    end)
  end

  defp translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
