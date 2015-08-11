require "cgi"
require "yaml"

NAME         = "weechat-naughty-notifier"
DESCRIPTION  = "Naughty notifications"
AUTHOR_EMAIL = "brian@lorf.org"
VERSION      = "0.1"
LICENSE      = "BSD3"

# XXX this causes load failure. why?
# class Hash
#   def by_path(*ks)
#     ks.inject(self) do |prev,k|
#       prev && prev[k] ? prev[k] : nil
#     end
#   end
# end

class AwesomeNotifier
  CONFIG_FILE_NAME = File.join(ENV["HOME"], ".weechat-naughty-notifier.conf")

  COLOR_DEFAULT = "#404040"
  COLOR_PRIVATE = "#a00020"

  def initialize(config_text=nil)
    @config = load_config(config_text || File.read(CONFIG_FILE_NAME))

    if @config["debug"]
      eval <<-_END_
        def debug; yield; end
        def debug_print(s); Weechat.print("", s); end
      _END_
    else
      eval <<-_END_
        def debug; end
        def debug_print(s); end
      _END_
    end
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  def notify_public_directed(channel, sender_nick, message, my_nick, color)
    channel, sender_nick, message = [channel, sender_nick, message].map{|e| CGI.escapeHTML(e)}
    message.gsub!(/\b(#{my_nick})\b/i, "<b>\\1</b>")
    text = [channel, sender_nick, message].join(" ")
    notify(text, color, @config["directed_sticky"])
  end

  def notify_public(channel, sender_nick, message, color)
    text = [channel, sender_nick, message].map{|e| CGI.escapeHTML(e)}.join(" ")
    notify(text, color)
  end

  def notify_private(sender_nick, message)
    text = [sender_nick, message].map{|e| CGI.escapeHTML(e)}.join(" ")
    notify(text, @config["color_private"], @config["private_sticky"])
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  def handle_irc_privmsg(data, buffer, date, tags, visible, highlight, prefix, message)
    debug do
      debug_print "handle_irc_privmsg("
      %w(data buffer date tags visible highlight prefix message).each do |param|
        debug_print "  #{param}: #{eval "#{param}.inspect"}"
      end
      debug_print ")"
    end
    tags = tags.split(",")
    if tags.include?("notify_message")
      server      = Weechat.buffer_get_string(buffer, "localvar_server")
      my_nick     = Weechat.buffer_get_string(buffer, "localvar_nick")
      channel     = Weechat.buffer_get_string(buffer, "localvar_channel")
      sender_nick = parse_sender_nick(prefix)
      debug do
        %w(server my_nick channel sender_nick).each do |v|
          debug_print "#{v}: #{eval "#{v}.inspect"}"
        end
      end
      if sender_nick != my_nick
        color = by_path(@config, "colors", server, channel)
        if message =~ /\b#{my_nick}\b/
          notify_public_directed(channel, sender_nick, message, my_nick, color || @config["color_default"])
        elsif color
          notify_public(channel, sender_nick, message, color)
        end
      end
    elsif tags.include?("notify_private")
      received_on = Weechat.buffer_get_string(Weechat.current_buffer(), "localvar_channel")
      sender_nick = parse_sender_nick(prefix)
      if sender_nick != received_on
        notify_private(sender_nick, message)
      end
    end
    Weechat::WEECHAT_RC_OK
  end

  # - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  private

  def by_path(h, *ks)
    ks.inject(h) do |prev,k|
      prev && prev[k] ? prev[k] : nil
    end
  end

  def debug(s)
    if @debug
      debug_print(s)
    end
  end

  def debug_print(s)
    Weechat.print("", s)
  end

  def notify(text, background_color, sticky = false)
    t = text.gsub("'", "\\\\'")
    c = background_color =~ /^#[0-9a-fA-F]{6}$/ ? background_color : @config["color_default"]
    s = sticky ? 0 : @config["default_timeout"]
    command = (
      "n = require('naughty');" +
      "n.notify({"              +
        "text='#{t}',"          +
        "bg='#{c}',"            +
        "fg='#ffffff',"         +
        "border_width=0,"       +
        "timeout=#{s},"         +
        "screen=mouse.screen"   +
      "});"
    )
    IO.popen("awesome-client", "r+") do |ac|
      ac.print(command)
    end
  end

  def parse_sender_nick(prefix)
    (prefix =~ /^[@%+~*&!-]/) ? prefix[1..-1] : prefix
  end

  def load_config(config_text)
    def expand_vars(x, vars)
      case x
      when Hash
        {}.tap do |h|
          x.each do |k,v|
            h[k] = expand_vars(v, vars)
          end
        end
      when String
        x.dup.tap do |s|
          ids = s.scan(/\$\{(\w+)\}/).flatten
          ids.each do |id|
            if var_val = vars[id]
              s.gsub!(/\$\{#{id}\}/, var_val)
            else
              raise "unknown id '#{id}'"
            end
          end
        end
      else
        expand_vars(x.to_s, vars)
      end
    end
    h = YAML.load(config_text)
    vars = h.delete("variables") || {}
    expand_vars(h, vars).tap do |c|
      c["debug"] = (c["debug"] and c["debug"] == true)
      c["color_default"] ||= COLOR_DEFAULT
      c["color_private"] ||= COLOR_PRIVATE
    end
  end
end

def handle_irc_privmsg(*args)
  $notifier.handle_irc_privmsg(*args)
end

def weechat_init
  $notifier = AwesomeNotifier.new
  Weechat.register(NAME, DESCRIPTION, VERSION, LICENSE, DESCRIPTION, "", "")
  Weechat.hook_print("", "irc_privmsg", "", 1, "handle_irc_privmsg", "")
  Weechat::WEECHAT_RC_OK
end

if $0 == __FILE__
  config_text = <<-_END_
    {
      "variables": {},
      "colors": {}
    }
  _END_
  AwesomeNotifier.new(config_text).tap do |n|
    n.notify_public_directed("#abc", "someguy", "james: hi james your name is james", "james", "#008000")
    n.notify_public("#foo", "someguy", "let's all agree to conquer fear", "#0060a0")
    n.notify_private("someguy", "my pound puppy mr snarf ate a quarter once")
  end
end
