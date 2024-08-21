defmodule AvispishLooperOld do
  alias Evision, as: CV

  # Product:   https://www.waveshare.com/wiki/1.69inch_LCD_Module
  # Datasheet: https://files.waveshare.com/upload/c/c9/ST7789V2.pdf
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

  @seq_dir Path.join(__DIR__, "files/avispish_looper")

  def create_display(opts \\ []) do
    opts
    |> Keyword.validate!(@waveshare_169_display_opts)
    |> ST7789.new()
  end

  def load_seq(file_name) do
    File.rm_rf!(@seq_dir)
    File.mkdir_p!(@seq_dir)

    seq_zip = Path.join(__DIR__, "files/#{file_name}.zip")

    {:ok, seq_frames} =
      seq_zip
      |> to_charlist()
      |> :zip.unzip([{:cwd, to_charlist(@seq_dir)}])

    seq_frames
    |> Enum.map(&to_string/1)
  end

  def start(display, seq) do
    Process.spawn(
      fn ->
        IO.puts("Avispish: Loading sequence...")
        frame_count = length(seq)

        seq
        |> Enum.with_index()
        |> Enum.each(fn {img_path, index} -> Process.put(:"img_#{index}", read_frame(img_path)) end)

        IO.puts("Avispish: Looper starting...")

        loop(display, frame_count)
      end,
      [{:priority, :max}, {:min_heap_size, 4_000_000}, {:min_bin_vheap_size, 4_000_000}]
    )
  end

  def play(looper_pid) do
    send(looper_pid, :play)
  end

  def stop(looper_pid) do
    send(looper_pid, :stop)
  end

  defp loop(display, size) do
    receive do
      :play ->
        IO.puts("Avispish: Looper playing...")
        send(self(), {:tick, 0, size})

        loop(display, size)

      {:tick, index, size} ->
        render_frame(display, Process.get(:"img_#{index}"))
        Process.send_after(self(), {:tick, next_index(index, size), size}, 1)

        loop(display, size)

      :stop ->
        IO.puts("Avispish: Looper stopped!")
        :ok
    end
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
