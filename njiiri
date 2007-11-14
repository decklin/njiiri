#!/usr/bin/env ruby

require 'libglade2'

class Njiiri
    TITLE = "Njiiri MPD Client"
    NAME = "Njiiri"
    VERSION = "0.1"

    def initialize(path, root = nil, domain = nil, localedir = nil,
                   flag = GladeXML::FILE)
        @glade = GladeXML.new(path) { |handler| method(handler) }
    end

    def on_quit(*widget)
        Gtk.main_quit
    end

    def on_browse_btn_clicked(*widget)
        @glade.get_widget("browser_win").show
    end

    def on_close_btn_clicked(*widget)
        @glade.get_widget("browser_win").hide
    end
end

Gtk.init
njiiri = Njiiri.new(File.dirname($0)+"/njiiri.glade", nil, Njiiri::NAME)
Gtk.main
