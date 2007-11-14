#!/usr/bin/env ruby

require 'libglade2'

class Njiiri
    TITLE = "Njiiri MPD Client"
    NAME = "Njiiri"
    VERSION = "0.1"

    def initialize(path, root = nil, domain = nil, localedir = nil,
                   flag = GladeXML::FILE)
        @glade = GladeXML.new(path) { |handler| method(handler) }
        self.create_size_group
    end

    def create_size_group
        sg1 = Gtk::SizeGroup.new(Gtk::SizeGroup::VERTICAL)
        sg1.add_widget(@glade.get_widget("bookmarks_hbox"))
        sg1.add_widget(@glade.get_widget("kind_hbox"))
        sg2 = Gtk::SizeGroup.new(Gtk::SizeGroup::HORIZONTAL)
        sg2.add_widget(@glade.get_widget("close_btn"))
        sg2.add_widget(@glade.get_widget("play_btn"))
        sg2.add_widget(@glade.get_widget("add_btn"))
    end

    def on_quit(*widget)
        Gtk.main_quit
    end

    def on_library_btn_clicked(*widget)
        @glade.get_widget("browser_win").show
    end

    def on_close_btn_clicked(*widget)
        @glade.get_widget("browser_win").hide
    end
end

Gtk.init
kari = Njiiri.new(File.dirname($0)+"/njiiri.glade", nil, Njiiri::NAME)
Gtk.main
