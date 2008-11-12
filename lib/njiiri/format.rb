require 'cgi'

class Format
  class << self
    def all(song, default=nil)
      dir, file = File.split(song.file)
      [ a(song.title, file, default),
        a(song.artist, song.name, default),
        a(song.album, dir, default),
        song.time ? pos(song.time.to_i) : '∞',
        song.track ]
    end
    def a(*l)
      l.find {|x| not (x.nil? or x.empty?) }
    end
    def h(s)
      CGI::escapeHTML(a(s, ' '))
    end
    def m(t)
      m, s = t.divmod(60); return '%d:%02d' % [m, s] if m < 80
      h, m = m.divmod(60); return '%d:%02d:%02d' % [h, m, s] if h < 24
      d, h = h.divmod(24); return '%dd %dh %dm' % [d, h, m]
    end
    def pl(a, n)
      "#{n} #{a}" + (n != 1 ? "s" : "")
    end
    def pos(*times)
      times.collect {|t| m(t) }.join(' / ')
    end
    def title(title)
      "<big><b>#{h(title)}</b></big>"
    end
    def artist(artist)
      "<big>#{h(artist)}</big>"
    end
    def album(album, track = nil)
      track = "track #{h(track)}, " if track
      "#{track}<i>#{h(album)}</i>"
    end
  end
end
