require 'libglade2'

class Geom < Struct.new(:x, :y, :w, :h, :pane, :columns); end

class Column < Struct.new(:name, :type, :title); end

class GladeWrapper < GladeXML
  def initialize(obj)
    Njiiri.find_share_path('njiiri.glade') do |path|
      super(path) {|handler| obj.method(handler) }
    end
  end

  def method_missing(name)
    self[name.to_s]
  end
end

class TreeTable
  attr_accessor :store

  def initialize(*cols)
    @cols = cols
    @store = Gtk::TreeStore.new(*@cols.collect {|c| c.type })
  end

  def create_columns(params={})
    @cols.each_with_index do |c, i|
      if c.title
        if c.type == Symbol
          r = Gtk::CellRendererPixbuf.new
          col = Gtk::TreeViewColumn.new(c.title, r, :stock_id => i)
        elsif c.type == String
          r = Gtk::CellRendererText.new
          r.ellipsize = Pango::ELLIPSIZE_END
          col = Gtk::TreeViewColumn.new(c.title, r, params.merge(:text => i))
          col.expand = true
        end
        col.sizing = Gtk::TreeViewColumn::FIXED
        col.resizable = true
        yield(col, i)
      end
    end
  end

  def [](name)
    @cols.index {|c| c.name == name}
  end
end

class Njiiri
  def on_add_btn_clicked(widget)
    add_songs
  end

  def on_bookmarks_sw_size_allocate(widget, a)
    @config.browser.pane = a.width
  end

  def on_bookmarks_tree_row_activated(widget, path, col)
    iter = @bookmarks_tree.store.get_iter(path)
    iter[@bookmarks_tree[:cb]].call
  end

  def on_browser_win_configure_event(widget, e)
    @config.browser.x = e.x
    @config.browser.y = e.y
    false
  end

  def on_browser_win_delete(widget, e)
    widget.hide
  end

  def on_browser_win_key_press_event(widget, e)
    if !@widgets.search_entry.has_focus? and e.keyval == '/'[0]
      browse_input_toggle(:add, true)
      @widgets.search_entry.text = 'http://'
      @widgets.search_entry.position = -1
      true
    else
      false
    end
  end

  def on_browser_win_show
    bookmarks = [ [ 'Library', proc do
                      browse_input_toggle(:add, false)
                      reset_pwd
                    end ],
                  [ 'Search', proc do
                      browse_input_toggle(:search, true)
                      @files_tree.store.clear
                    end ],
                  [ '-', proc { } ] ] +
                  @mpd.playlists.collect do |pl|
                    [ pl, proc { @mpd.load(pl) } ]
                  end
    @bookmarks_tree.store.clear
    bookmarks.each do |n, p|
      iter = @bookmarks_tree.store.append(nil)
      iter[@bookmarks_tree[:places]] = n
      iter[@bookmarks_tree[:cb]] = p
    end
  end

  def on_browser_win_size_allocate(widget, a)
    @config.browser.w = a.width
    @config.browser.h = a.height
    false
  end

  def on_cancel_btn_clicked
    @widgets.saveas_dlg.hide
  end

  def on_clear_btn_clicked
    @mpd.clear
  end

  def on_close_btn_clicked(widget)
    @widgets.browser_win.hide
  end

  def on_conn_cancel_btn_clicked
    @widgets.connect_dlg.hide
  end

  def on_recent_btn_button_press_event(widget, event)
    origin_x, origin_y = widget.parent_window.origin
    alloc = widget.allocation
    @widgets.recent_menu.popup(nil, nil, event.button, event.time) do
      [origin_x + alloc.x, origin_y + alloc.y + alloc.height]
    end
  end

  def on_connect_btn_clicked(widget)
    @widgets.connect_dlg.show
  end

  def on_disconnect_btn_clicked(widget)
    @mpd.disconnect
    disconnected('closed by user')
  end

  def on_do_connect_btn_clicked
    @widgets.connect_dlg.hide
    @mpd.disconnect if @mpd.connected?
    connect(Server.new(@widgets.host_entry.text, @widgets.port_entry.text.to_i,
                       @widgets.password_entry.text))
  end

  def on_files_tree_row_activated(widget, path, col)
    iter = @files_tree.store.get_iter(path)
    iter[@files_tree[:cb]].call
  end

  def on_files_tree_size_allocate(widget, a)
    @config.browser.columns = widget.columns.collect {|w| w.width }
  end

  def on_info_box_size_allocate(widget, a)
    if @widgets.cover_img.width_request == a.height
      @widgets.cover_img.height_request = 1
    else
      @widgets.cover_img.width_request = a.height
      @widgets.cover_img.height_request = a.height
      draw_cover
    end
    @config.player.pane = a.height
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
      @widgets.search_hbox.show
    else
      @widgets.search_hbox.hide
    end
  end

  def on_next_btn_clicked
    @mpd.next
  end

  def on_open_btn_clicked
    @widgets.browser_win.move(@config.browser.x, @config.browser.y)
    @widgets.browser_win.show
  end

  def on_pause_btn_clicked(widget)
    @mpd.pause = true
  end

  def on_play_btn_clicked(widget)
    @mpd.play
  end

  def on_player_win_configure_event(widget, e)
    @config.player.x = e.x
    @config.player.y = e.y
    false
  end

  def on_player_win_delete(widget, e)
    @config.save
    Gtk.main_quit
  end

  def on_player_win_size_allocate(widget, a)
    @config.player.w = a.width
    @config.player.h = a.height
    false
  end

  def on_playlist_selection_changed
    refresh_selection
  end

  def on_playlist_tree_key_press_event(widget, e)
    if e.keyval == Gdk::Keyval::GDK_Delete
      delete_sel(@widgets.playlist_tree.selection)
    end
  end

  def on_playlist_tree_row_activated(widget, path, col)
    iter = @player_tree.store.get_iter(path)
    @mpd.seekid(iter[@player_tree[:id]], 0)
  end

  def on_playlist_tree_size_allocate(widget, a)
    @config.player.columns = widget.columns.collect {|w| w.width }
  end

  def on_pos_bar_button_press_event(widget, e)
    if @mpd.playing? or @mpd.paused?
      seek_to = (e.x / widget.allocation.width) * @mpd.current_song.time.to_i
      @mpd.seek(@mpd.current_song.pos, seek_to.to_i)
      schedule(:got_time) {}
    end
  end

  def on_prev_btn_clicked
    @mpd.previous
  end

  def on_random_btn_toggled(widget)
    @mpd.random = widget.active?
  end

  def on_repeat_btn_toggled(widget)
    @mpd.repeat = widget.active?
  end

  def on_root_btn_clicked(widget)
    reset_pwd
  end

  def on_save_btn_clicked
    @mpd.save(@widgets.name_entry.text)
    @widgets.saveas_dlg.hide
  end

  def on_saveas_btn_clicked
    @widgets.saveas_dlg.show
  end

  def on_shuffle_btn_clicked(widget)
    @mpd.shuffle
  end

  def on_status_exp_activate(widget)
    @widgets.mode_box.visible = !widget.expanded?
  end

  def on_cue_item_activate(widget)
    @cue_next = true
  end

  def on_stop_item_activate(widget)
    @mpd.stop
  end

  def on_top_item_activate(widget)
    @mpd.play 0
  end

  def on_update_btn_clicked(widget)
    @mpd.update rescue nil
  end

  def on_volume_scale_value_changed(widget)
    schedule(:got_volume) { @mpd.volume = widget.value.to_i }
  end

  def on_playlist_tree_button_press_event(widget, event)
    if event.kind_of? Gdk::EventButton and event.button == 3
      @widgets.context_menu.popup(nil, nil, event.button, event.time)
    end
  end

  def on_playlist_tree_popup_menu(widget)
    @widgets.context_menu.popup(nil, nil, 0, Gtk.current_event_time)
  end

  def on_playlist_tree_drag_data_get(widget, ctx, data, info, time)
    sources = []
    @widgets.playlist_tree.selection.selected_each do |model, path, iter|
      sources << [path.indices[0], iter[@player_tree[:id]]]
    end
    data.text = YAML::dump(sources)
  end

  def on_playlist_tree_drag_data_received(widget, ctx, x, y, data, info, time)
    sources = YAML::load(data.text)
    path, disposition = @widgets.playlist_tree.get_dest_row(x, y)

    if path.nil? or disposition.nil?
      # i have no idea why it does this for drag-beyond-end
      orig_dest = @mpd.playlist_len
    else
      orig_dest = path.indices[0]
      # we treat all of BEFORE, INTO_OR_BEFORE, INTO_OR_AFTER as 'before'
      if disposition == Gtk::TreeView::DropPosition::AFTER
        orig_dest += 1
      end
    end

    offset = 0
    sources.each do |index, song_id|
      if orig_dest > index
        # if moving ahead, all the subsequent indexes decrease by 1
        dest = orig_dest + offset - 1
      else
        # if moving back, next one will need to go after it
        dest = orig_dest + offset
        offset += 1
      end

      # now fixup
      if dest < index
        # we moved it back, so all indexes inbetween increased by 1
        sources.select {|i,s| (dest+1..index).member?(i) }.each do |i,s|
          i += 1
        end
      else
        # we moved it ahead, so all indexes inbetween decreased by 1
        sources.select {|i,s| (index+1..dest).member?(i) }.each do |i,s|
          i -= 1
        end
      end

      @mpd.moveid(song_id, dest)
    end

    # lame
    @widgets.playlist_tree.selection.unselect_all

    ctx.drop_finish(true, time)
  end

  def on_selectall_item_activate(widget)
    @widgets.playlist_tree.selection.select_all
  end

  def on_invert_item_activate(widget)
    @player_tree.store.each do |model, path, iter|
      invert_path(@widgets.playlist_tree.selection, path)
    end
  end

  def on_remove_item_activate(widget)
    delete_sel(@widgets.playlist_tree.selection)
  end

  def invert_path(sel, path)
    if sel.path_is_selected?(path)
      sel.unselect_path(path)
    else
      sel.select_path(path)
    end
  end

  def delete_sel(sel)
    sel.selected_each do |model, path, iter|
      sel.unselect_iter(iter)
      @mpd.stop if @mpd.current_song.id == iter[@player_tree[:id]]
      @mpd.deleteid(iter[@player_tree[:id]])
    end
  end

  def make_cover(color)
    raw = @cover_tmpl.pixels.unpack('L*')
    xor = raw.collect {|x| x ^ color }.pack('L*')
    Gdk::Pixbuf.new(xor, @cover_tmpl.colorspace, true, 8,
                    @cover_tmpl.width, @cover_tmpl.height,
                    @cover_tmpl.rowstride).saturate_and_pixelate(0.5, false)
  end

  def draw_cover
    @widgets.cover_img.pixbuf = @cover.scale(@widgets.cover_img.width_request,
                                             @widgets.cover_img.width_request,
                                             Gdk::Pixbuf::INTERP_BILINEAR)
  end
end
