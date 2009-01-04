require 'yaml'

class NjiiriConfig
  DEFAULTS = {
    :servers => [ Server.new('localhost', 6600, '') ],
    :geometry => {
      :player => Geom.new(0, 0, 720, 400, 80, [28, 180, 160, 140, 40]),
      :browser => Geom.new(0, 0, 720, 400, 100, [28, 140, 120, 100, 40])
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
