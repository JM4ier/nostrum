defmodule Nostrum.Voice.Audio do
  @moduledoc false

  require Logger

  alias Nostrum.Error.VoiceError
  alias Nostrum.Struct.VoiceState
  alias Nostrum.Util
  alias Nostrum.Voice
  alias Porcelain.Process, as: Proc

  @encryption_mode "xsalsa20_poly1305"
  @samples_per_frame 960
  @usec_per_frame 20_000
  # How many consecutive packets to send before resting
  @frames_per_burst 10

  def encryption_mode, do: @encryption_mode

  def rtp_header(%VoiceState{} = voice) do
    <<
      0x80::8,
      0x78::8,
      voice.rtp_sequence::16,
      voice.rtp_timestamp::32,
      voice.ssrc::32
    >>
  end

  def encrypt_packet(%VoiceState{} = voice, data) do
    header = rtp_header(voice)
    # 12 byte header + 12 null bytes
    nonce = header <> <<0::96>>
    header <> Kcl.secretbox(data, nonce, voice.secret_key)
  end

  def open_udp do
    {:ok, socket} =
      :gen_udp.open(0, [
        :binary,
        {:active, false},
        {:reuseaddr, true}
      ])

    socket
  end

  def init_player(voice) do
    take_nap()
    player_loop(voice)
  end

  def player_loop(voice, init? \\ true) do
    t1 = Util.usec_now()
    voice = try_send_data(voice, init?)
    t2 = Util.usec_now()

    take_nap(t2 - t1)

    player_loop(voice, false)
  end

  def take_nap(diff \\ 0) do
    ((@usec_per_frame * @frames_per_burst - diff) / 1000)
    |> trunc()
    |> max(0)
    |> Process.sleep()
  end

  def get_source(%VoiceState{ffmpeg_proc: nil, raw_audio: raw_audio}), do: raw_audio

  def get_source(%VoiceState{ffmpeg_proc: ffmpeg_proc}), do: ffmpeg_proc.out

  def try_send_data(%VoiceState{} = voice, init?) do
    init_timeout = Application.get_env(:nostrum, :audio_timeout, 20_000)
    running_timeout = Application.get_env(:nostrum, :audio_running_timeout, 500)
    wait = if(init?, do: init_timeout, else: running_timeout)
    {:ok, watchdog} = :timer.apply_after(wait, __MODULE__, :on_stall, [voice])

    {voice, done} =
      voice
      |> get_source()
      |> Enum.take(@frames_per_burst)
      |> send_frames(voice)

    :timer.cancel(watchdog)

    if done,
      do: on_complete(voice, init?),
      else: voice
  end

  def try_send_data(_, _), do: :ok

  def send_frames(frames, %VoiceState{} = voice) do
    voice =
      Enum.reduce(frames, voice, fn f, v ->
        :gen_udp.send(
          v.udp_socket,
          v.ip |> ip_to_tuple(),
          v.port,
          encrypt_packet(v, f)
        )

        %{
          v
          | rtp_sequence: v.rtp_sequence + 1,
            rtp_timestamp: v.rtp_timestamp + @samples_per_frame
        }
      end)

    {Voice.update_voice(voice.guild_id,
       rtp_sequence: voice.rtp_sequence,
       rtp_timestamp: voice.rtp_timestamp,
       # If using raw audio and it isn't stateful, update its state manually
       raw_audio:
         unless(is_nil(voice.raw_audio) or voice.raw_stateful,
           do: Enum.slice(voice.raw_audio, @frames_per_burst..-1)
         )
     ), length(frames) < @frames_per_burst}
  end

  def spawn_youtubedl(url) do
    res =
      Porcelain.spawn(
        Application.get_env(:nostrum, :youtubedl, "youtube-dl"),
        [
          ["-f", "bestaudio"],
          ["-o", "-"],
          ["-q"],
          [url]
        ]
        |> List.flatten(),
        out: :stream
      )

    case res do
      {:error, reason} ->
        raise(VoiceError, reason: reason, executable: "youtube-dl")

      proc ->
        proc
    end
  end

  def spawn_ffmpeg(input, type \\ :url, options \\ []) do
    {input_url, stdin} =
      case type do
        :url ->
          {input, <<>>}

        :pipe ->
          {"pipe:0", input}

        :ytdl ->
          %Proc{out: outstream} = spawn_youtubedl(input)

          {"pipe:0", outstream}
      end

    res =
      Porcelain.spawn(
        Application.get_env(:nostrum, :ffmpeg, "ffmpeg"),
        [
          ffmpeg_options(options, input_url),
          ["-ac", "2"],
          ["-ar", "48000"],
          ["-f", "s16le"],
          ["-acodec", "libopus"],
          ["-loglevel", "quiet"],
          ["pipe:1"]
        ]
        |> List.flatten(),
        in: stdin,
        out: :stream
      )

    case res do
      {:error, reason} ->
        raise(VoiceError, reason: reason, executable: "ffmpeg")

      proc ->
        proc
    end
  end

  def ffmpeg_options(options, input_url) do
    # Volume
    vol_opt =
      case Keyword.get(options, :volume) do
        val when is_number(val) -> [filter: "volume=#{val}"]
        _ -> []
      end

    [
      # Start position
      case Keyword.get(options, :start_pos) do
        nil -> []
        val -> ["-ss", val]
      end,

      # Duration
      case Keyword.get(options, :duration) do
        nil -> []
        val -> ["-t", val]
      end,

      # Realtime Processing
      if(Keyword.get(options, :realtime, true), do: ["-re"], else: []),

      # Input URL
      ["-i", input_url],

      # Filters
      case Keyword.get_values(options ++ vol_opt, :filter) do
        [] -> []
        val -> ["-af", Enum.join(val, ", ")]
      end
    ]
  end

  def on_stall(%VoiceState{} = voice) do
    unless is_nil(voice.ffmpeg_proc) do
      Proc.stop(voice.ffmpeg_proc)
    end
  end

  def on_complete(%VoiceState{} = voice, timed_out) do
    Voice.update_voice(voice.guild_id, ffmpeg_proc: nil, raw_audio: nil)
    List.duplicate(<<0xF8, 0xFF, 0xFE>>, 5) |> send_frames(voice)
    Voice.set_speaking(voice, false, timed_out)
    Process.exit(voice.player_pid, :stop)
  end

  @doc """
  Because UDP is connectionless, we must discover our machine's external
  IP and port used to communicate via the UDP socket to inform the discord
  voice server where to send incoming voice data. This is a bot library, so
  it's unlikely it will be listening to any incoming voice data, but it's
  here for completeness/correctness.
  """
  def discover_ip(socket, ip, port, ssrc) do
    ip_tuple = ip_to_tuple(ip)

    req_packet =
      <<
        # '1' for request
        1::16,
        # length of rest
        70::16,
        ssrc::32
      >> <>
        (ip |> String.pad_trailing(64, <<0>>)) <>
        <<port::16>>

    :ok = :gen_udp.send(socket, ip_tuple, port, req_packet)
    {:ok, res_packet} = :gen_udp.recv(socket, 74)

    {
      ^ip_tuple,
      ^port,
      <<
        2::16,
        70::16,
        ^ssrc::32,
        my_ip::bitstring-size(512),
        my_port::16
      >>
    } = res_packet

    my_ip = my_ip |> String.trim(<<0>>)
    {my_ip, my_port}
  end

  defp ip_to_tuple(ip) do
    {:ok, ip_tuple} =
      ip
      |> String.to_charlist()
      |> :inet_parse.address()

    ip_tuple
  end
end
