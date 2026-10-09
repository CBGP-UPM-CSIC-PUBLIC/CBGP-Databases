# frozen_string_literal: true

require 'cgi'
require_relative '../theme'

module Mcp
  module Widgets
    # What every drawn picture shares, whatever it shows: the HTML page around it (responsive, following
    # the viewer's dark mode, with a "Download SVG" link and a browser-made "Download PNG" button), the
    # standalone SVG file (what the download carries and what a server-made PNG is drawn from), and the
    # note lines under the picture (the theme's footer, a chart's caption).
    #
    # A widget hands over only its shapes (+inner+, a width and a height) and its own style rules. Shapes
    # take colours from CSS variables - --bg --fg --muted --band --grid --hl from the theme, --c0, --c1 ...
    # for the colours of that picture's categories - written like  style="fill:var(--c2)" . On the page
    # the variables have a light and a dark value; in the standalone SVG every variable is replaced by its
    # light value, because editors and librsvg (which draws the PNG) do not all read CSS variables.
    module Frame
      TITLE_H = 30
      NOTE_H = 15
      NOTE_CHAR_W = 5.7 # average width of a note character at 10.5px

      WORDS = {
        'en' => { download: 'Download SVG', download_png: 'Download PNG', download_data: 'Download the numbers', title: 'Chart', file: 'chart' },
        'es' => { download: 'Descargar SVG', download_png: 'Descargar PNG', download_data: 'Descargar los datos', title: 'Gráfico', file: 'grafico' }
      }.freeze

      # The page can make its own PNG, in the viewer's browser: the SVG (carried in the "Download SVG" link)
      # is drawn onto a canvas at twice its size and saved. No server involved, so no converter, no file path
      # and no extra payload. Where scripts are blocked (a sandboxed frame) the link stays hidden and the SVG
      # link still works; in a saved or separately opened page it appears.
      PNG_SCRIPT = <<~JS.freeze
        (function(){
          if(!document.createElement('canvas').getContext) return;
          window.cbgpChartPng=function(done,svgId){
            var svgLink=document.getElementById(svgId||'dlsvg'), img=new Image();
            img.onload=function(){
              var w=(img.naturalWidth||960)*2, h=(img.naturalHeight||300)*2, c=document.createElement('canvas');
              c.width=w; c.height=h;
              var x=c.getContext('2d'); x.fillStyle='#fff'; x.fillRect(0,0,w,h); x.drawImage(img,0,0,w,h);
              c.toBlob(done,'image/png');
            };
            img.src=svgLink.href;
          };
          Array.prototype.forEach.call(document.querySelectorAll('a[id^=dlpng]'),function(pngLink){
            var svgId=pngLink.id.replace('dlpng','dlsvg'), svgLink=document.getElementById(svgId);
            if(!svgLink) return;
            pngLink.hidden=false;
            pngLink.addEventListener('click',function(ev){
              ev.preventDefault();
              window.cbgpChartPng(function(blob){
                var url=URL.createObjectURL(blob), a=document.createElement('a');
                a.href=url; a.download=pngLink.getAttribute('data-name'); document.body.appendChild(a); a.click(); a.remove();
                setTimeout(function(){URL.revokeObjectURL(url);},2000);
              },svgId);
            });
          });
        })();
      JS

      module_function

      def esc(text)
        CGI.escapeHTML(text.to_s)
      end

      # A coordinate for an SVG attribute: one decimal at most, no trailing ".0" (a very long decimal such as
      # 401.56164383561645 costs bytes in every shape of every picture and shows nothing).
      def n(value)
        format('%.1f', value.to_f).sub(/\.0\z/, '')
      end

      # A reference to the n-th colour of the picture, for use in an inline style.
      def colour(index)
        "var(--c#{index})"
      end

      # The text colour that reads on top of the n-th colour.
      def ink(index)
        "var(--k#{index})"
      end

      # The notes under a picture: the caption lines a chart passes, then the theme's footer.
      def notes_for(theme, notes)
        (Array(notes) + [theme.footer]).compact.map { |n| n.to_s.strip }.reject(&:empty?)
      end

      # The colour variables of a picture: --c0.. are its category colours and --k0.. the text colour that
      # reads on top of each (white or near-black), each with a light and a dark value.
      def colour_vars(colours, dark: false)
        colours.each_with_index.each_with_object({}) do |(c, i), out|
          shown = dark ? Theme.for_dark(c) : c
          out["c#{i}"] = shown
          out["k#{i}"] = Theme.ink(shown)
        end
      end

      # How tall the notes block of a standalone picture is (0 when there are none).
      def notes_height(theme, notes, width)
        lines = notes_for(theme, notes).flat_map { |n| wrap(n, note_chars(width)) }
        lines.empty? ? 0 : (lines.size * NOTE_H) + 8
      end

      # How many characters of a note fit on one line of a picture +width+ wide.
      def note_chars(width)
        [((width - 16) / NOTE_CHAR_W).floor, 30].max
      end

      def css_vars(theme, colours)
        light = theme.light.merge(colour_vars(colours))
        dark = theme.dark.merge(colour_vars(colours, dark: true))
        declare = ->(map) { map.map { |k, v| "--#{k}:#{v}" }.join(';') }
        ":root{#{declare.(light)}}\n@media (prefers-color-scheme:dark){:root{#{declare.(dark)}}}\n"
      end

      def page_css(theme)
        <<~CSS
          body{margin:0;padding:12px 16px;background:var(--bg);color:var(--fg);font:13px #{theme.font}}
          h1{font-size:16px;margin:0 0 8px}
          .note{margin:4px 0 0;font-size:11px;color:var(--muted)}
          .dl{margin:6px 0 0;font-size:12px}.dl a{color:var(--muted)}.dl a+a{margin-left:12px}
        CSS
      end

      # Every var(--x) in +text+ replaced by its light value.
      def resolve(text, theme, colours)
        values = theme.light.merge(colour_vars(colours))
        text.gsub(/var\(--(\w+)\)/) { values.fetch(Regexp.last_match(1), '#000000') }
      end

      # A file name for a download, from the title ("alvarez-alfageme-olga.svg").
      def file_name(title, words, extension = 'svg')
        slug = title.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
        "#{slug.empty? ? words[:file] : slug}.#{extension}"
      end

      def wrap(text, width)
        text.to_s.gsub(/\s+/, ' ').scan(/\S.{0,#{width - 1}}(?=\s|\z)|\S+/).map(&:strip)
      end

      # The page: heading, the picture, notes, download links, the PNG script.
      def html_page(inner:, width:, height:, title:, words:, language:, svg:, rules:, theme:, colours:, notes: [], variants: [], data: nil)
        shown = title.to_s.empty? ? words[:title] : title
        heading = title.to_s.empty? ? '' : "<h1>#{esc(title)}</h1>"
        note_html = notes_for(theme, notes).map { |n| %(<p class="note">#{esc(n)}</p>) }.join("\n")
        links = download_links(title, words, svg, variants, data)
        <<~HTML
          <!doctype html>
          <html lang="#{language}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{esc(shown)}</title>
          <style>#{css_vars(theme, colours)}#{page_css(theme)}#{rules}</style></head>
          <body>#{heading}
          <svg viewBox="0 0 #{width.to_i} #{height}" width="100%" role="img" aria-label="#{esc(shown)}">#{inner}</svg>
          #{note_html}
          #{links}
          <script>#{PNG_SCRIPT}</script>
          </body></html>
        HTML
      end

      # The download links under a picture: SVG and PNG for the picture shown, the same for each other shape
      # (+variants+: [{ svg:, label: }]), and the numbers behind it (+data+: tab-separated text) for Excel.
      def download_links(title, words, svg, variants, data)
        pictures = [{ svg: svg, label: nil }] + Array(variants)
        parts = pictures.each_with_index.map do |pic, i|
          suffix = i.zero? ? '' : (i + 1).to_s
          tag = pic[:label] ? " (#{pic[:label]})" : ''
          extra = pic[:label] ? "-#{Theme.key(pic[:label]).gsub(/[^a-z0-9]+/, '-')}" : ''
          name = ->(ext) { file_name(title, words, ext).sub(/\.#{ext}\z/, "#{extra}.#{ext}") }
          %(<a id="dlsvg#{suffix}" download="#{esc(name.('svg'))}" href="data:image/svg+xml;base64,#{[pic[:svg]].pack('m0')}">#{esc(words[:download])}#{esc(tag)}</a>) +
            %( <a id="dlpng#{suffix}" data-name="#{esc(name.('png'))}" href="#" hidden>#{esc(words[:download_png])}#{esc(tag)}</a>)
        end
        if data
          parts << %(<a id="dltsv" download="#{esc(file_name(title, words, 'tsv'))}" href="data:text/tab-separated-values;charset=utf-8;base64,#{["\uFEFF#{data}"].pack('m0')}">#{esc(words[:download_data])}</a>)
        end
        %(<p class="dl">#{parts.join(' ')}</p>)
      end

      # A standalone SVG: valid on its own (namespace, size, own styles), literal light colours, a background,
      # the title and the note lines drawn into the picture.
      def standalone(inner:, width:, height:, title:, words:, rules:, theme:, colours:, notes: [])
        top = title.to_s.empty? ? 0 : TITLE_H
        lines = notes_for(theme, notes).flat_map { |n| wrap(n, note_chars(width)) }
        notes_h = lines.empty? ? 0 : (lines.size * NOTE_H) + 8
        total = height + top + notes_h + 4
        heading = title.to_s.empty? ? '' : %(<text class="title" x="8" y="20">#{esc(title)}</text>)
        base = height + top + 14
        foot = lines.each_with_index.map { |l, i| %(<text class="note" x="8" y="#{base + (i * NOTE_H)}">#{esc(l)}</text>) }.join
        svg = <<~SVG.strip
          <?xml version="1.0" encoding="UTF-8"?>
          <svg xmlns="http://www.w3.org/2000/svg" width="#{width.to_i}" height="#{total}" viewBox="0 0 #{width.to_i} #{total}" role="img" aria-label="#{esc(title.to_s.empty? ? words[:title] : title)}">
          <style>#{rules}text{font-family:#{theme.font}}.title{font-size:16px;font-weight:700;fill:var(--fg)}.note{font-size:10.5px;fill:var(--muted)}</style>
          <rect width="#{width.to_i}" height="#{total}" style="fill:var(--bg)"/>
          #{heading}<g transform="translate(0,#{top})">#{inner}</g>#{foot}
          </svg>
        SVG
        resolve(svg, theme, colours)
      end
    end
  end
end
