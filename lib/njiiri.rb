#!/usr/bin/ruby

require 'rubygems'
require 'librmpd'
require 'thread'
require 'libglade2'
require 'cgi'
require 'yaml'

class Array
  def sum; inject(0) {|a, b| a + b }; end
end

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

class GladeWrapper < GladeXML
  def initialize(obj)
    Njiiri.search('njiiri.glade') do |path|
      super(path) {|handler| obj.method(handler) }
    end
  end

  def method_missing(name)
    self[name.to_s]
  end
end

class Server < Struct.new(:host, :port, :password)
  def to_s
    port == 6600 ? host : "#{host}:#{port}"
  end
end

class Geom < Struct.new(:x, :y, :w, :h, :pane, :columns); end

class Njiiri
  NAME = 'Njiiri'
  SHARE_DIRS = %w[share /usr/local/share/njiiri /usr/share/njiiri
                  /opt/local/usr/share/njiiri]

  PLAYER_COLS = [ [ '', Symbol ],
                  [ 'Title', String ],
                  [ 'Artist', String ],
                  [ 'Album', String ],
                  [ 'Time', String ],
                  [ :id, String ],
                  [ :weight, Integer ],
                  [ :len, Integer ] ]
  BROWSE_COLS = [ [ '', Symbol ],
                  [ 'Title', String ],
                  [ 'Artist', String ],
                  [ 'Album', String ],
                  [ 'Time', String ],
                  [ :path, String ],
                  [ :cb, Proc ] ]
  BOOKMK_COLS = [ [ 'Places', String ],
                  [ :cb, Proc ] ]

  # CLASS

  @@callbacks = []

  def self.search(filename)
    SHARE_DIRS.each do |dir|
      path = "#{dir}/#{filename}"
      if File.exist?(path)
        return yield(path)
      end
    end
  end

  def initialize(rc_path)
    @config = Conf.new(rc_path)
    @widgets = GladeWrapper.new(self)

    @prev_version = 0
    @btab = {}
    @tasks = {}
    @mutex = Mutex.new

    Njiiri.search('blank-album.png') do |path|
      @cover = Gdk::Pixbuf.new(path)
    end

    @player_tree_store = Gtk::TreeStore.new(*PLAYER_COLS.collect{|n, t| t })
    @widgets.playlist_tree.model = @player_tree_store
    @widgets.playlist_tree.selection.mode = Gtk::SELECTION_MULTIPLE
    @widgets.playlist_tree.selection.signal_connect('changed') do
      on_playlist_selection_changed
    end

    PLAYER_COLS.each_with_index do |spec, i|
      name, type = spec
      make_column(name, type, i, :weight => 6) do |col|
        col.sizing = Gtk::TreeViewColumn::FIXED
        col.fixed_width = @config.player.columns[i]
        unless i == 0
          col.resizable = true
          col.expand = true
        end
        @widgets.playlist_tree.append_column(col)
      end
    end

    @files_tree_store = Gtk::TreeStore.new(*BROWSE_COLS.collect{|n, t| t })
    @widgets.files_tree.model = @files_tree_store
    @widgets.files_tree.selection.mode = Gtk::SELECTION_MULTIPLE

    BROWSE_COLS.each_with_index do |spec, i|
      name, type = spec
      make_column(name, type, i) do |col|
        col.sizing = Gtk::TreeViewColumn::FIXED
        col.fixed_width = @config.browser.columns[i]
        unless i == 0
          col.resizable = true
          col.expand = true
        end
        @widgets.files_tree.append_column(col)
      end
    end

    @bookmarks_tree_store = Gtk::TreeStore.new(*BOOKMK_COLS.collect{|n, t| t })
    @widgets.bookmarks_tree.model = @bookmarks_tree_store

    BOOKMK_COLS.each_with_index do |spec, i|
      name, type = spec
      make_column(name, type, i) do |col|
        col.resizable = false
        @widgets.bookmarks_tree.append_column(col)
      end
    end

    build_server_menu

    @widgets.player_win.set_default_size(@config.player.w, @config.player.h)
    @widgets.main_pane.set_position(@config.player.pane)

    @widgets.browser_win.set_default_size(@config.browser.w, @config.browser.h)
    @widgets.files_pane.set_position(@config.browser.pane)

    @widgets.player_win.move(@config.player.x, @config.player.y)
    @widgets.player_win.focus = @widgets.kludge_sep
    @widgets.player_win.show
  end

  def make_column(name, type, i, params={})
    if name.class == String
      if type == String
        rend = Gtk::CellRendererText.new
        rend.ellipsize = Pango::ELLIPSIZE_END
        yield Gtk::TreeViewColumn.new(name, rend, params.merge(:text => i))
      elsif type == Symbol
        rend = Gtk::CellRendererPixbuf.new
        yield Gtk::TreeViewColumn.new(name, rend, :stock_id => i)
      end
    end
  end

  def build_server_menu
    @widgets.connect_menu.children.each do |w|
      @widgets.connect_menu.remove(w) unless w == @widgets.disconnect_item
    end
    @config.servers.each do |srv|
      item = Gtk::ImageMenuItem.new(Gtk::Stock::NETWORK)
      item.child.label = srv.to_s
      item.signal_connect("activate") do |widget, event|
        @mpd.disconnect if @mpd.connected?
        connect(srv)
      end
      @widgets.connect_menu.append(item)
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
    rescue => e
      STDERR.puts "Error connecting: #{e}"
      disconnected
    end
  end

  def connected
    @tasks.clear
    @widgets.status_label.label = "#{@ack} on #{@server}"
    @widgets.random_btn.active = @mpd.random?
    @widgets.repeat_btn.active = @mpd.repeat?
    @widgets.volume_scale.value = @mpd.volume
    @widgets.xfade_spin.value = @mpd.crossfade
    enable_controls(true)
    rebuild_playlist(0)
    reset_pwd
  end

  def disconnected
    @tasks.clear
    @widgets.status_label.label = "Disconnected from #{@server}"
    @player_tree_store.clear
    @files_tree_store.clear
    enable_controls(false)
  end

  def enable_controls(sensitive)
    %w[open_btn saveas_btn play_btn pause_btn prev_btn next_btn shuffle_btn
       clear_btn volume_scale detail_label random_btn repeat_btn sel_label
       xfade_label xfade_spin].each {|w| @widgets[w].sensitive = sensitive }
  end

  # MAIN WINDOW

  def on_player_win_delete(widget, e)
    @config.save
    Gtk.main_quit
  end

  def on_info_box_size_allocate(widget, a)
    if @widgets.cover_img.width_request == a.height
      @widgets.cover_img.height_request = 1
    else
      @widgets.cover_img.width_request = a.height
      @widgets.cover_img.height_request = a.height
      @widgets.cover_img.pixbuf = @cover.scale(a.height, a.height,
                                               Gdk::Pixbuf::INTERP_NEAREST)
    end
    @config.player.pane = a.height
  end

  def on_player_win_size_allocate(widget, a)
    @config.player.w = a.width
    @config.player.h = a.height
    false
  end

  def on_player_win_configure_event(widget, e)
    @config.player.x = e.x
    @config.player.y = e.y
    false
  end

  def on_browser_win_size_allocate(widget, a)
    @config.browser.w = a.width
    @config.browser.h = a.height
    false
  end

  def on_browser_win_configure_event(widget, e)
    @config.browser.x = e.x
    @config.browser.y = e.y
    false
  end

  def on_pos_bar_button_press_event(widget, e)
    if @mpd.connected? and (@mpd.playing? or @mpd.paused?)
      seek_to = (e.x / widget.allocation.width) * @mpd.current_song.time.to_i
      @mpd.seek(@mpd.current_song.pos, seek_to.to_i)
      schedule(:got_time) {}
    end
  end

  def on_playlist_tree_row_activated(widget, path, col)
    iter = @player_tree_store.get_iter(path)
    @mpd.seekid(iter[5], 0)
  end

  def on_playlist_tree_key_press_event(widget, e)
    if e.keyval == Gdk::Keyval::GDK_Delete
      @widgets.playlist_tree.selection.selected_each do |model, path, iter|
        @widgets.playlist_tree.selection.unselect_iter(iter)
        @mpd.deleteid(iter[5])
      end
    end
  end

  def on_playlist_selection_changed
    times = []
    @widgets.playlist_tree.selection.selected_each {|m, p, i| times << i[7] }
    refresh_selection(times)
  end

  def on_status_exp_activate(widget)
    @widgets.mode_box.visible = !widget.expanded?
  end

  def on_playlist_tree_size_allocate(widget, a)
    @config.player.columns = widget.columns.collect {|w| w.width }
  end

  # TOOLBAR

  def on_play_btn_clicked(widget)
    @mpd.play
  end

  def on_pause_btn_clicked(widget)
    @mpd.pause = true
  end

  def on_stop_item_activate(widget)
    @mpd.stop
  end

  def on_prev_btn_clicked
    @mpd.previous
  end

  def on_next_btn_clicked
    @mpd.next
  end

  def on_open_btn_clicked
    @widgets.browser_win.move(@config.browser.x, @config.browser.y)
    @widgets.browser_win.show
  end

  def on_saveas_btn_clicked
    @widgets.saveas_dlg.show
  end

  def on_clear_btn_clicked
    @mpd.clear
  end

  def on_shuffle_btn_clicked(widget)
    @mpd.shuffle
  end

  def on_random_btn_toggled(widget)
    @mpd.random = widget.active?
  end

  def on_repeat_btn_toggled(widget)
    @mpd.repeat = widget.active?
  end

  def on_connect_btn_clicked(widget)
    @widgets.connect_dlg.show
  end

  def on_disconnect_item_activate(widget)
    @mpd.disconnect
    disconnected
  end

  def on_volume_scale_value_changed(widget)
    schedule(:got_volume) { @mpd.volume = widget.value.to_i }
  end

  def on_xfade_spin_value_changed(widget)
    schedule(:got_xfade) { @mpd.crossfade = widget.value.to_i }
  end

  def on_player_toolbar_popup_context_menu(x, y, button, user_data)
    @widgets.toolbar_menu.popup(nil, nil, button, Gtk.current_event_time)
  end

  # BROWSER WINDOW

  def on_browser_win_show
    bookmarks = [ [ 'Library', proc { reset_pwd } ],
                  [ 'Search', proc { activate_search_entry('_Search:') } ],
                  [ '-', proc { } ] ] +
                @mpd.playlists.collect { |pl| [ pl, proc { @mpd.load(pl) } ] }
    @bookmarks_tree_store.clear
    bookmarks.each do |n, p|
      iter = @bookmarks_tree_store.append(nil)
      iter[0] = n
      iter[1] = p
    end
  end

  def on_bookmarks_sw_size_allocate(widget, a)
    @config.browser.pane = a.width
  end

  def add_pwd(dir)
    @pwd << dir

    @widgets.breadcrumb_box.children[1..-1].each_with_index do |child, i|
      if child.label != @pwd[i] or i >= @pwd.length-1
        @widgets.breadcrumb_box.remove(child)
        @btab.delete(child)
      end
    end

    btn = Gtk::Button.new(dir, false)
    @btab[btn] = @pwd.join('/')
    btn.signal_connect('clicked') {|w| up_pwd(@btab[w].split('/')) }
    @widgets.breadcrumb_box.add(btn)
    btn.show

    load_pwd
  end

  def load_pwd
    @files_tree_store.clear
    pwd = @pwd.join('/')
    @mpd.lsinfo(pwd, :directories).each do |path|
      dir = File.basename(path)
      iter = @files_tree_store.append(nil)
      iter[0] = Gtk::Stock::DIRECTORY
      iter[1], iter[2], iter[3], iter[4] = dir, '-', '-', '-'
      iter[5] = path
      iter[6] = proc { add_pwd(dir) }
    end
    @mpd.lsinfo(pwd, :files).each do |path|
      song = @mpd.listallinfo(path)[0]
      iter = @files_tree_store.append(nil)
      iter[0] = Gtk::Stock::FILE
      iter[1], iter[2], iter[3], iter[4] = Format.all(song, '-')
      iter[5] = path
      iter[6] = proc { @mpd.add path }
    end
  end

  def reset_pwd
    @pwd = [];
    load_pwd
  end

  def up_pwd(wd)
    @pwd = wd;
    load_pwd
  end

  def on_bookmarks_tree_row_activated(widget, path, col)
    iter = @bookmarks_tree_store.get_iter(path)
    iter[1].call
  end

  def on_files_tree_row_activated(widget, path, col)
    iter = @files_tree_store.get_iter(path)
    iter[6].call
  end

  def on_browser_win_key_press_event(widget, e)
    if !@widgets.search_entry.has_focus? and e.keyval == '/'[0]
      @widgets.loc_btn.active = true
      @widgets.search_entry.text = 'http://'
      @widgets.search_entry.grab_focus
      @widgets.search_entry.position = -1
      true
    else
      false
    end
  end

  def add_songs
    if @widgets.search_entry.text.empty?
      add_by_id = proc do |model, path, iter|
        @mpd.add(iter[5])
      end
      if @widgets.files_tree.selection.selected_rows.empty?
        @widgets.files_tree.model.each &add_by_id
      else
        @widgets.files_tree.selection.selected_each &add_by_id
      end
    else
      @mpd.add(@widgets.search_entry.text) rescue nil
      @widgets.search_entry.text = ''
    end
  end

  def on_add_btn_clicked(widget)
    add_songs
  end

  def insert_songs(default)
    orig_pos = @mpd.stopped? ? default - 1 : @mpd.status['song'].to_i
    orig_len = @mpd.playlist_len
    add_songs
    if orig_len != 0
      pos = orig_pos
      src = orig_len - 1
      len = @mpd.playlist_len
      @mpd.move(src += 1, pos += 1) while src < len - 1
    end
    orig_pos + 1
  end

  def on_insert_btn_clicked(widget)
    insert_songs(0)
  end

  def on_jump_btn_clicked(widget)
    pos = insert_songs(@mpd.playlist_len)
    @mpd.play(pos)
  end

  def on_loc_btn_toggled(widget)
    if widget.active?
      activate_search_entry('_Location:')
    else
      @widgets.search_hbox.hide
    end
  end

  def on_root_btn_clicked(widget)
    reset_pwd
  end

  def on_update_btn_clicked(widget)
    @mpd.update rescue nil
  end

  def on_browser_win_delete(widget, e)
    widget.hide
  end

  def on_close_btn_clicked(widget)
    @widgets.browser_win.hide
  end

  def activate_search_entry(label)
    @widgets.search_hbox.show
    @widgets.search_label.label = label
    @widgets.search_entry.grab_focus
  end
  
  def on_files_tree_size_allocate(widget, a)
    @config.browser.columns = widget.columns.collect {|w| w.width }
  end

  # SAVE AS DIALOG

  def on_cancel_btn_clicked
    @widgets.saveas_dlg.hide
  end

  def on_save_btn_clicked
    @mpd.save(@widgets.name_entry.text)
    @widgets.saveas_dlg.hide
  end

  # CONNECT DIALOG

  def on_conn_cancel_btn_clicked
    @widgets.connect_dlg.hide
  end

  def on_do_connect_btn_clicked
    @widgets.connect_dlg.hide
    @mpd.disconnect if @mpd.connected?
    connect(Server.new(@widgets.host_entry.text, @widgets.port_entry.text.to_i,
                       @widgets.password_entry.text))
  end

  # CALLBACKS

  def schedule(slot, &block)
    @mutex.synchronize { @tasks[slot] = block }
  end

  def pending
    @mutex.synchronize do
      blocks = @@callbacks.collect {|n, t, cb| @tasks[n] }.compact
      @tasks.clear
      return blocks
    end
  end

  def wake
    pending.each {|block| block.call }
  end

  def self.def_cb(name, tag, &block)
    cb = "_cb_#{tag}"
    @@callbacks << [name, tag, cb]
    class_eval do
      define_method name, &block
      define_method cb do |*args|
        schedule(name) { self.send(name, *args) }
      end
    end
  end

  # yes, the order of these is important

  def_cb :got_connection, MPD::CONNECTION_CALLBACK do |up|
    up ? connected : disconnected
  end

  def_cb :got_time, MPD::TIME_CALLBACK do |elapsed, total|
    refresh_pos(elapsed, total)
  end

  def_cb :got_song, MPD::CURRENT_SONG_CALLBACK do |current|
    refresh_info(current)
    refresh_playlist
    schedule(:got_time) {}
    refresh_pos(*@mpd.current_time)
  end

  def_cb :got_state, MPD::STATE_CALLBACK do |state|
    refresh_state(state)
  end

  def_cb :got_playlist, MPD::PLAYLIST_CALLBACK do |version|
    rebuild_playlist(version)
    refresh_playlist
    refresh_detail
  end

  def_cb :got_volume, MPD::VOLUME_CALLBACK do |vol|
    @widgets.volume_scale.value = vol
    schedule(:got_volume) {}
  end

  def_cb :got_xfade, MPD::CROSSFADE_CALLBACK do |secs|
    @widgets.xfade_spin.value = secs
    schedule(:got_xfade) {}
  end

  def_cb :got_random, MPD::RANDOM_CALLBACK do |random|
    @widgets.random_btn.active = random
  end

  def_cb :got_repeat, MPD::REPEAT_CALLBACK do |repeat|
    @widgets.repeat_btn.active = repeat
  end

  # MISC

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
    if @mpd.connected?
      cur_songid = @mpd.status['songid']
      @player_tree_store.each do |model, path, iter|
        if iter[5] == cur_songid
          iter[0] = Gtk::Stock::MEDIA_PLAY
          iter[6] = Pango::WEIGHT_BOLD
        else
          iter[0] = nil
          iter[6] = Pango::WEIGHT_NORMAL
        end
      end
      refresh_selection
    end
  end

  def rebuild_playlist(version, prev=@prev_version)
    if @mpd.connected?
      @mpd.playlist_changes(prev).each do |song|
        iter = @player_tree_store.get_iter(song['pos']) \
            || @player_tree_store.append(nil)
        iter[1], iter[2], iter[3], iter[4] = Format.all(song, '-')
        iter[5] = song.id
        iter[7] = song.time.to_i
      end
      if last = @player_tree_store.get_iter(@mpd.playlist_len.to_s)
        1 while @player_tree_store.remove(last)
      end
      @prev_version = version
    end
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
  end

  def refresh_pos(elapsed=0, total=0)
    if @mpd.connected? and (@mpd.playing? or @mpd.paused?)
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
    if @mpd.connected?
      @widgets.detail_label.label = "Library: " +
        "#{Format.pl('song', @mpd.stats['songs'].to_i)}, " +
        "#{Format.pl('artist', @mpd.stats['artists'].to_i)}, " +
        "#{Format.pl('album', @mpd.stats['albums'].to_i)}, " +
        "#{Format.pos(@mpd.stats['db_playtime'].to_i)}\n" +
        "Last updated: #{Time.at(@mpd.stats['db_update'].to_i).ctime}"
    end
  end

  def refresh_selection(times=[])
    if @mpd.connected?
      times = @mpd.playlist.collect {|s| s.time.to_i } if times.size <= 1
      @widgets.sel_label.label = "#{Format.pl('song', times.size)}, " +
                                 "#{Format.pos(times.sum)}"
    end
  end
end

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

class Conf
  DEFAULTS = {
    :servers => [ Server.new('localhost', 6600, '') ],
    :geometry => {
      :player => Geom.new(0, 0, 600, 500, 80, [40, 180, 160, 140, 40]),
      :browser => Geom.new(0, 0, 600, 400, 100, [40, 140, 120, 100, 40])
    }
  }

  def initialize(path)
    @path = path
    @rc = DEFAULTS.merge begin
      File.open(path) {|f| YAML::load(f) }
    rescue
      {}
    end
  end

  def save
    begin
      File.open(@path, 'w') {|f| YAML::dump(@rc, f) }
    rescue => e
      STDERR.puts "Error saving config: #{e}"
    end
  end

  def player; @rc[:geometry][:player]; end
  def browser; @rc[:geometry][:browser]; end
  def servers; @rc[:servers]; end
  def add_server(server)
    @rc[:servers].reject! {|srv| srv.to_s == server.to_s }
    @rc[:servers] = [server] + @rc[:servers][0..4]
  end
end
