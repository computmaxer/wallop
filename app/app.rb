EventMachine.run do
  module Wallop
    class App < Sinatra::Base
      enable :logging

      configure do
        mime_type :m3u8, 'application/x-mpegURL'
        mime_type :ts, 'video/MP2T'
      end

      get '/' do
        redirect '/channels'
      end

      get '/channels' do
        @channels = Wallop.lineup
        @channels.map{|c| %{<p><a href="/channels/#{c['GuideNumber']}/tune?wait=true">#{c['GuideNumber']} - #{c['GuideName']}</a></p>}}.join
      end

      get '/channels/:channel/tune' do
        resolution = params[:resolution] || '1280x720'
        bitrate = params[:bitrate] || '3000k'

        channel = params[:channel]

        if !Wallop.sessions.has_key?(channel)
          Wallop.cleanup_channel(channel)
          Wallop.logger.info "Tuning channel #{channel} with quality settings of #{resolution} @ #{bitrate}"
          pid  = POSIX::Spawn::spawn(Wallop.ffmpeg_command(channel, resolution, bitrate))
          Process::waitpid(pid, Process::WNOHANG)
          Wallop.logger.info "Creating session for channel #{channel}"
          Wallop.sessions[params[:channel]] = {:channel => channel, :pid => pid, :ready => false, :last_read => Time.now}
        end

        if params[:wait]
          until Wallop.sessions[params[:channel]][:ready] do
            sleep(0.5)
          end
        end

        redirect "/channels/#{channel}.m3u8"
      end

      get '/channels/:channel/status' do
        session = Wallop.sessions[params[:channel]]
        halt 404 if !session

        content_type :json
        JSON.dump(session)
      end

      get '/channels/:channel/stop' do
        Wallop.logger.info "Stopping channel #{params[:channel]}"

        session = Wallop.sessions[params[:channel]]
        halt 404 if !session

        if Process.kill('QUIT', session[:pid])
          Process::waitpid(session[:pid])
          Wallop.cleanup_channel(session[:channel])
          Wallop.sessions.delete(session[:channel])
        end

        "OK"
      end

      get '/channels/:channel.m3u8' do
        session = Wallop.sessions[params[:channel]]
        halt 404 if !session

        halt 420 if !session[:ready]

        session[:last_read] = Time.now

        send_file("#{session[:channel]}.m3u8")
      end

      get %r{/(\d+.ts)} do
        send_file(params[:captures].first)
      end
    end
  end

  EventMachine.add_periodic_timer(0.5) { Wallop.sweep_sessions }
  Wallop::App.run!(:port=>Wallop.config['PORT'])
end