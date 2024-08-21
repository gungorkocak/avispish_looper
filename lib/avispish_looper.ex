defmodule AvispishLooper do
  use GenServer

  require Logger

  alias Evision, as: CV

  @waveshare_169_display_opts [
    port: 0,
    cs: 0,
    rst: 27,
    dc: 25,
    backlight: 18,
    width: 280,
    height: 240,
    speed_hz: 120 * 1000 * 1000,
    invert: false,
    offset_left: 20
  ]

  @seq_zip Path.join("/data/livebook", "files/avispish_seq.zip")
  @seq_dir Path.join("/data/livebook", "files/avispish_looper")

  # Public API
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [display_opts: @waveshare_169_display_opts, seq_zip: @seq_zip, seq_dir: @seq_dir, autoplay: false])

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start(opts \\ []) do
    opts = Keyword.validate!(opts, [display_opts: @waveshare_169_display_opts, seq_zip: @seq_zip, seq_dir: @seq_dir, autoplay: false])

    GenServer.start(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  def play do
    GenServer.cast(__MODULE__, :play)
  end

  def pause do
    GenServer.cast(__MODULE__, :pause)
  end

  def load(seq_zip) do
    GenServer.call(__MODULE__, {:load, seq_zip})
  end

  @impl true
  def init(opts) do
    Logger.info("[#{__MODULE__}]: Initializing")

    initial_state = %{
      seq_zip: opts[:seq_zip],
      display_opts: opts[:display_opts],
      autoplay: opts[:autoplay],
      display: nil,
      frames: [],
      frame_count: 0,
      current_index: 0,
      playing?: false
    }

    {:ok, initial_state, {:continue, :autoload}}
  end

  @impl true
  def terminate(reason, %{display: display} = _state) do
    Logger.info("[#{__MODULE__}]: Stopping with reason: #{inspect(reason)}")
    :ok = Circuits.SPI.close(display.spi)
    :ok = Circuits.GPIO.close(display.gpio[:dc])
    :ok = Circuits.GPIO.close(display.gpio[:backlight])
    :ok = Circuits.GPIO.close(display.gpio[:rst])
    Logger.info("[#{__MODULE__}]: Stopped!")
  end

  @impl true
  def handle_continue(:autoload, state) do
    Logger.info("[#{__MODULE__}]: Autoloading")

    %{seq_zip: seq_zip, display_opts: display_opts, autoplay: autoplay} = state

    Logger.info("[#{__MODULE__}]: Creating display...")
    state = %{state | display: create_display(display_opts)}

    Logger.info("[#{__MODULE__}]: Loading frames from cache...")
    state =
      case load_frames(seq_zip) do
        {:ok, frame_count, frames} ->
          Logger.info("[#{__MODULE__}]: Autoplaying cached sequence...")

          %{state | frames: frames, frame_count: frame_count, current_index: 0}

        {:error, reason} ->
          Logger.error("[#{__MODULE__}]: Error while loading frames: #{inspect(reason)}")

          state
      end

    Logger.info("[#{__MODULE__}]: Initialized display and loaded frames")

    if autoplay do
      {:noreply, state, {:continue, :autoplay}}
    else
      {:noreply, state}
    end
  end

  def handle_continue(:autoplay, %{frames: []} = state) do
    Logger.info("[#{__MODULE__}]: No frames to autoplay...")
    {:noreply, state}
  end

  def handle_continue(:autoplay, state) do
    IO.puts("[#{__MODULE__}]: Autoplaying...")
    send(self(), :tick)
    {:noreply, %{state | playing?: true}}
  end

  @impl true
  def handle_call({:load, seq_zip}, _from, state) do
    IO.puts("[#{__MODULE__}]: Loading new sequence: #{seq_zip}...")

    with {:ok, frame_count, frames} <- load_frames(seq_zip) do
      save_seq(seq_zip)

      {:reply, :ok, %{state | frame_count: frame_count, frames: frames, current_index: 0}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast(:play, state) do
    IO.puts("[#{__MODULE__}]: Playing...")
    send(self(), :tick)
    {:noreply, %{state | playing?: true}}
  end

  @impl true
  def handle_cast(:pause, state) do
    IO.puts("[#{__MODULE__}]: Paused")

    {:noreply, %{state | playing?: false}}
  end

  @impl true
  def handle_info(:tick, %{playing?: true} = state) do
    %{display: display, frames: frames, frame_count: size, current_index: index} = state

    render_frame(display, Map.get(frames, index))
    Process.send_after(self(), :tick, 1)
    new_index = next_index(index, size)

    {:noreply, %{state | current_index: new_index}}
  end

  def handle_info(:tick, state) do
    {:noreply, state}
  end

  defp create_display(opts) do
    ST7789.new(opts)
  end

  defp load_frames(seq_zip) do
    if File.exists?(seq_zip) do
      seq = load_seq(seq_zip)
      frame_count = length(seq)

      frames =
        seq
        |> Enum.with_index()
        |> Enum.map(fn {img_path, index} -> {index, read_frame(img_path)} end)
        |> Enum.into(%{})

      IO.puts("[#{__MODULE__}]: Loaded #{frame_count} frames for: #{seq_zip}")

      {:ok, frame_count, frames}
    else
      {:error, :seq_not_found}
    end
  end

  defp load_seq(seq_zip) do
    File.rm_rf!(@seq_dir)
    File.mkdir_p!(@seq_dir)

    {:ok, seq_frames} =
      seq_zip
      |> to_charlist()
      |> :zip.unzip([{:cwd, to_charlist(@seq_dir)}])

    seq_frames
    |> Enum.map(&to_string/1)
  end

  defp save_seq(seq_zip) do
    IO.puts("[#{__MODULE__}]: Caching seq #{seq_zip} to #{@seq_zip}...")
    File.cp!(seq_zip, @seq_zip)
  end

  defp read_frame(path) do
    path
    |> CV.imread()
    |> CV.rotate(CV.RotateFlags.cv_ROTATE_90_CLOCKWISE())
    |> CV.Mat.to_binary()
  end

  defp render_frame(display, img_frame) do
    ST7789.display(display, img_frame, :bgr)
  end

  defp next_index(current_index, size) when current_index >= size - 1 do
    0
  end

  defp next_index(current_index, _size) do
    current_index + 1
  end
end
