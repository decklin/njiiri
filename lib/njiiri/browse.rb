class Njiiri
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
    btn.signal_connect('clicked') {|w| cd(@btab[w].split('/')) }
    @widgets.breadcrumb_box.add(btn)
    btn.show

    load_pwd
  end

  def load_pwd
    @files_tree.store.clear
    browse_input_toggle(:add, false)
    pwd = @pwd.join('/')
    @mpd.lsinfo(pwd, :directories).each do |path|
      browse_add_dir(path)
    end
    @mpd.lsinfo(pwd, :files).each do |path|
      browse_add_file(path)
    end
  end

  def browse_add_dir(path)
    dir = File.basename(path)
    iter = @files_tree.store.append(nil)
    iter[@files_tree[:icon]] = Gtk::Stock::DIRECTORY
    iter[1], iter[2], iter[3], iter[4] = dir, '-', '-', '-'
    iter[@files_tree[:path]] = path
    iter[@files_tree[:cb]] = proc { add_pwd(dir) }
  end

  def browse_add_file(path)
    song = @mpd.listallinfo(path)[0]
    iter = @files_tree.store.append(nil)
    title, artist, album, time, track = Format.all(song , '-')
    iter[@files_tree[:icon]] = Gtk::Stock::FILE
    iter[@files_tree[:title]] = title
    iter[@files_tree[:artist]] = artist
    iter[@files_tree[:album]] = album
    iter[@files_tree[:time]] = time
    iter[@files_tree[:path]] = path
    iter[@files_tree[:cb]] = proc { @mpd.add path }
  end

  def reset_pwd
    @pwd = [];
    load_pwd
  end

  def cd(wd)
    @pwd = wd;
    load_pwd
  end

  def add_songs
    if @widgets.search_entry.text.empty?
      if @widgets.files_tree.selection.selected_rows.empty?
        @widgets.files_tree.model.each do |model, path, iter|
          @mpd.add(iter[@files_tree[:path]])
        end
      else
        @widgets.files_tree.selection.selected_each do |model, path, iter|
          @mpd.add(iter[@files_tree[:path]])
        end
      end
    else
      case @browse_input_mode
      when :add
        @mpd.add(@widgets.search_entry.text) rescue nil
      when :search
        do_search(@widgets.search_entry.text)
      end
      @widgets.search_entry.text = ''
    end
  end

  def do_search(query)
    @files_tree.store.clear
    %w[title artist album].collect do |field|
      @mpd.search(field, query)
    end.flatten.each do |hit|
      browse_add_file(hit['file'])
    end
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

  def browse_input_toggle(mode, show)
    @browse_input_mode = mode
    @widgets.search_label.label = BROWSE_INPUT_LABELS[mode]
    if show
      @widgets.search_entry.text = ''
      @widgets.loc_btn.active = true
      @widgets.search_hbox.show
      @widgets.search_entry.grab_focus
    else
      @widgets.loc_btn.active = false
      @widgets.search_hbox.hide
    end
  end
end
