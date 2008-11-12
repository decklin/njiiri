require 'thread'
require 'rubygems'
require 'librmpd'

class MPD
  def lsinfo(path = '/', type = :files)
    response = send_command "lsinfo \"#{path}\""
    case type
      when :files
        filter_response response, /\Afile: /i
      when :directories
        filter_response response, /\Adirectory: /i
      when :playlists
        filter_response response, /\Aplaylist: /i
    end
  end
  def listallinfo(path=nil)
    songs(path)
  end
  def playlist_len
    status['playlistlength'].to_i
  end
  def current_time
    status['time'].split(':').collect {|x| x.to_i } rescue [0, 0]
  end
  class Song
    def id; self['id']; end
  end
end

class Server < Struct.new(:host, :port, :password)
  def to_s
    port == 6600 ? host : "#{host}:#{port}"
  end
end
