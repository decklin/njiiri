require 'njiiri/mpd'
require 'njiiri/gtk'
require 'njiiri/config'
require 'njiiri/browse'
require 'njiiri/format'

class Array
  def sum; inject(0) {|a, b| a + b }; end
end

class Njiiri
  NAME = 'Njiiri'
  BROWSE_INPUT_LABELS = { :add => "_Location:", :search => "_Search:" }
  SHARE_DIRS = %w[share /usr/local/share/njiiri /usr/share/njiiri
                  /opt/local/usr/share/njiiri]

  def self.find_share_path(filename)
    SHARE_DIRS.each do |dir|
      path = "#{dir}/#{filename}"
      if File.exist?(path)
        return yield(path)
      end
    end
  end

  def initialize(rc_path)
    @config = NjiiriConfig.new(rc_path)
    @widgets = GladeWrapper.new(self)

    @btab = {}
    @tasks = {}
    @mutex = Mutex.new
    @prev_version = 0
    @browse_input_mode = nil
    @cue_next = false

    Njiiri.find_share_path('blank-album.png') do |path|
      @cover = @cover_tmpl = Gdk::Pixbuf.new(path)
    end

    @player_tree = TreeTable.new(Column.new(:icon, Symbol, ''),
                                 Column.new(:title, String, 'Title'),
                                 Column.new(:artist, String, 'Artist'),
                                 Column.new(:album, String, 'Album'),
                                 Column.new(:time, String, 'Time'),
                                 Column.new(:id, String),
                                 Column.new(:weight, Integer),
                                 Column.new(:len, Integer))

    @widgets.playlist_tree.model = @player_tree.store
    @widgets.playlist_tree.selection.mode = Gtk::SELECTION_MULTIPLE
    @player_tree.create_columns(:weight => @player_tree[:weight]) do |col, i|
      col.fixed_width = @config.player.columns[i]
      @widgets.playlist_tree.append_column(col)
    end
    @widgets.playlist_tree.selection.signal_connect('changed') do
      on_playlist_selection_changed
    end

    @files_tree = TreeTable.new(Column.new(:icon, Symbol, ''),
                                Column.new(:title, String, 'Title'),
                                Column.new(:artist, String, 'Artist'),
                                Column.new(:album, String, 'Album'),
                                Column.new(:time, String, 'Time'),
                                Column.new(:path, String),
                                Column.new(:cb, Proc))

    @widgets.files_tree.model = @files_tree.store
    @widgets.files_tree.selection.mode = Gtk::SELECTION_MULTIPLE
    @files_tree.create_columns do |col, i|
      col.fixed_width = @config.browser.columns[i]
      @widgets.files_tree.append_column(col)
    end

    @bookmarks_tree = TreeTable.new(Column.new(:places, String, 'Places'),
                                    Column.new(:cb, Proc))

    @widgets.bookmarks_tree.model = @bookmarks_tree.store
    @bookmarks_tree.create_columns do |col, i|
      @widgets.bookmarks_tree.append_column(col)
    end

    build_server_menu

    @widgets.player_win.set_default_size(@config.player.w, @config.player.h)
    @widgets.main_pane.set_position(@config.player.pane)

    @widgets.browser_win.set_default_size(@config.browser.w, @config.browser.h)
    @widgets.files_pane.set_position(@config.browser.pane)

    @widgets.player_win.move(@config.player.x, @config.player.y)
    @widgets.player_win.focus = @widgets.kludge_sep
    @widgets.player_win.show

    # ugly hack to get the "icon and label" part of the menubutton
    [@widgets.play_btn, @widgets.pause_btn].each do |b|
      b.child.children[0].width_request = @widgets.open_btn.allocation.width
    end
  end

  def build_server_menu
    @widgets.recent_menu.children.each do |w|
      @widgets.recent_menu.remove(w) unless w == @widgets.disconnect_item
    end
    @config.servers.each do |srv|
      item = Gtk::ImageMenuItem.new(Gtk::Stock::NETWORK)
      item.child.label = srv.to_s
      item.signal_connect("activate") do |widget, event|
        @mpd.disconnect if @mpd.connected?
        connect(srv)
      end
      @widgets.recent_menu.append(item)
      item.show
    end
  end

  def connect(server=nil)
    @server = server || @config.servers.first
    @mpd = MPD.new(@server.host, @server.port)
    @@callbacks.each {|n, t, cb| @mpd.register_callback(method(cb), t) }
    begin
      @widgets.status_label.label = "Connecting..."
      @ack = @mpd.connect(true).match(/^OK (.*)/)[1]
      @mpd.password(@server.password) unless @server.password.empty?
      @widgets.host_entry.text = @server.host
      @widgets.port_entry.text = @server.port.to_s
      @widgets.password_entry.text = @server.password
      @config.add_server(@server)
      build_server_menu
    rescue Exception => e
      disconnected(e)
    end
  end

  def connected
    @tasks.clear
    @widgets.status_label.label = "#{@ack} on #{@server}"
    @widgets.random_btn.active = @mpd.random?
    @widgets.repeat_btn.active = @mpd.repeat?
    @widgets.volume_scale.value = @mpd.volume
    enable_controls(true)
    rebuild_playlist(0)
    reset_pwd
  end

  def disconnected(reason)
    @tasks.clear
    @widgets.status_label.label = "Disconnected from #{@server} (#{reason})"
    @player_tree.store.clear
    @files_tree.store.clear
    enable_controls(false)
  end

  def enable_controls(connected)
    %w[open_btn saveas_btn play_btn pause_btn prev_btn next_btn shuffle_btn
        clear_btn volume_scale random_btn repeat_btn sel_label].each do |w|
      @widgets[w].sensitive = connected
    end

    if connected
      @widgets.connect_btn.hide
      @widgets.disconnect_btn.show
    else
      @widgets.disconnect_btn.hide
      @widgets.connect_btn.show
    end
  end

  def refresh_state(state)
    if state == 'play'
      @widgets.play_btn.hide
      @widgets.pause_btn.show
      @widgets.kludge_sep.width_request = -1
    else
      refresh_pos if state == 'stop'
      @widgets.pause_btn.hide
      @widgets.play_btn.show
      @widgets.kludge_sep.width_request = 1
    end
  end

  def refresh_playlist
    cur_songid = @mpd.status['songid']
    @player_tree.store.each do |model, path, iter|
      if iter[@player_tree[:id]] == cur_songid
        iter[@player_tree[:icon]] = Gtk::Stock::MEDIA_PLAY
        iter[@player_tree[:weight]] = Pango::WEIGHT_BOLD
      else
        iter[@player_tree[:icon]] = nil
        iter[@player_tree[:weight]] = Pango::WEIGHT_NORMAL
      end
    end
    refresh_selection
  end

  def rebuild_playlist(version, prev=@prev_version)
    @mpd.playlist_changes(prev).each do |song|
      iter = @player_tree.store.get_iter(song['pos']) \
          || @player_tree.store.append(nil)
      title, artist, album, time, track = Format.all(song , '-')
      iter[@player_tree[:title]] = title
      iter[@player_tree[:artist]] = artist
      iter[@player_tree[:album]] = album
      iter[@player_tree[:time]] = time
      iter[@player_tree[:id]] = song.id
      iter[@player_tree[:len]] = song.time.to_i
    end
    if last = @player_tree.store.get_iter(@mpd.playlist_len.to_s)
      1 while @player_tree.store.remove(last)
    end
    @prev_version = version
  end

  def refresh_info(current)
    if current
      title, artist, album, time, track = Format.all(current)
      @widgets.player_win.title = [title, artist].join(' - ')
    else
      @widgets.player_win.title = NAME
    end
    @widgets.title_label.label = Format.title(title)
    @widgets.artist_label.label = Format.artist(artist)
    @widgets.album_label.label = Format.album(album, track)
    @cover = make_cover(Format.color(artist, album))
    draw_cover
  end

  def refresh_pos(elapsed=0, total=0)
    if @mpd.playing? or @mpd.paused?
      if total > 0
        @widgets.pos_bar.text = Format.pos(elapsed, total)
        @widgets.pos_bar.fraction = [elapsed.to_f / total, 1.0].min rescue 0.0
      else
        @widgets.pos_bar.text = Format.pos(elapsed)
        @widgets.pos_bar.pulse
      end
    else
      @widgets.pos_bar.text = total > 0 ? Format.pos(total) : ' '
      @widgets.pos_bar.fraction = 0.0
    end
  end

  def refresh_detail
    @widgets.sum_label.label = "Library: " +
      "#{Format.pl('song', @mpd.stats['songs'].to_i)}, " +
      "#{Format.pl('artist', @mpd.stats['artists'].to_i)}, " +
      "#{Format.pl('album', @mpd.stats['albums'].to_i)}, " +
      "#{Format.pos(@mpd.stats['db_playtime'].to_i)}"
    @widgets.update_btn.tooltip_text =
      "Last updated: #{Time.at(@mpd.stats['db_update'].to_i).ctime}"
  end

  def refresh_selection
    times = []
    if @widgets.playlist_tree.selection.count_selected_rows > 1
      @widgets.playlist_tree.selection.selected_each {|m, p, i| times << i[7] }
      n = "#{times.size} selected"
    else
      @widgets.playlist_tree.model.each {|m, p, i| times << i[7] }
      n = Format.pl('song', times.size)
    end
    @widgets.sel_label.label = "#{n}, #{Format.pos(times.sum)}"
  end
end
