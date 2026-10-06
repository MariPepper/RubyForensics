# frozen_string_literal: true

module FileIntegrityComparator
  # Menu interactivo para escolher opções de execução quando o
  # utilizador não as passa por linha de comandos.
  #
  # Só é invocado quando o stdin é um TTY (terminal interactivo).
  # Em pipelines ou scripts, os defaults são usados sem perguntar.
  class Menu
    STRATEGIES = {
      "1" => {
        key: :greedy,
        label: "Ganancioso (rápido, O(D×I×L²))",
        description: "Cada linha eliminada escolhe o melhor par disponível. " \
                     "Bom para blocos pequenos; pode falhar em blocos ambíguos."
      },
      "2" => {
        key: :hungarian,
        label: "Húngaro (óptimo, O(n³))",
        description: "Atribuição de custo total mínimo. Simétrico e determinístico. " \
                     "Recomendado para uso forense."
      }
    }.freeze

    NORMALIZATIONS = {
      "1" => {
        key: :nfc,
        label: "NFC (default, recomendado)",
        description: "Forma canónica composta. 'e' + acento -> 'é' (1 code point). " \
                     "É o que os sistemas modernos usam."
      },
      "2" => {
        key: :nfd,
        label: "NFD (decomposição canónica)",
        description: "Forma canónica decomposta. 'é' -> 'e' + acento (2 code points). " \
                     "Útil para comparar com sistemas que usam NFD."
      },
      "3" => {
        key: :none,
        label: "Nenhuma",
        description: "Compara os bytes textuais como estão. Útil quando a codificação " \
                     "é ela própria objecto de análise."
      }
    }.freeze

    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
    end

    def self.interactive?
      $stdin.tty? && $stdout.tty?
    end

    # Devolve um hash com as opções escolhidas:
    #   { strategy:, normalize:, max_absolute:, relative_ratio: }
    def ask(current)
      @output.puts
      @output.puts "=" * 60
      @output.puts "  COMPARAÇÃO DE INTEGRIDADE — CONFIGURAÇÃO"
      @output.puts "=" * 60
      @output.puts

      strategy = ask_strategy(current[:strategy])
      normalize = ask_normalization(current[:normalize])
      max_abs  = ask_integer("Máximo absoluto de edições (default #{current[:max_absolute]})",
                             current[:max_absolute])
      ratio    = ask_float("Fracção do comprimento da linha (default #{current[:relative_ratio]})",
                           current[:relative_ratio])

      {
        strategy: strategy,
        normalize: normalize,
        max_absolute: max_abs,
        relative_ratio: ratio
      }
    end

    private

    def ask_strategy(default)
      @output.puts "Algoritmo de emparelhamento de linhas:"
      @output.puts
      STRATEGIES.each do |key, info|
        marker = info[:key] == default ? " (default)" : ""
        @output.puts "  #{key}) #{info[:label]}#{marker}"
        @output.puts "     #{info[:description]}"
        @output.puts
      end

      loop do
        @output.print "Escolha [1-2, Enter para default]: "
        answer = @input.gets
        answer = answer.to_s.strip

        return default if answer.empty?
        return STRATEGIES[answer][:key] if STRATEGIES.key?(answer)

        @output.puts "Opção inválida. Tente novamente."
      end
    end

    def ask_normalization(default)
      @output.puts "Normalização Unicode antes de comparar:"
      @output.puts
      NORMALIZATIONS.each do |key, info|
        marker = info[:key] == default ? " (default)" : ""
        @output.puts "  #{key}) #{info[:label]}#{marker}"
        @output.puts "     #{info[:description]}"
        @output.puts
      end

      loop do
        @output.print "Escolha [1-3, Enter para default]: "
        answer = @input.gets
        answer = answer.to_s.strip

        return default if answer.empty?
        return NORMALIZATIONS[answer][:key] if NORMALIZATIONS.key?(answer)

        @output.puts "Opção inválida. Tente novamente."
      end
    end

    def ask_integer(prompt, default)
      loop do
        @output.print "#{prompt}: "
        answer = @input.gets
        answer = answer.to_s.strip

        return default if answer.empty?

        if answer.match?(/\A\d+\z/)
          value = answer.to_i
          return value if value.positive?

          @output.puts "Tem de ser um inteiro positivo."
        else
          @output.puts "Valor inválido."
        end
      end
    end

    def ask_float(prompt, default)
      loop do
        @output.print "#{prompt}: "
        answer = @input.gets
        answer = answer.to_s.strip

        return default if answer.empty?

        begin
          value = Float(answer)
          if value.positive? && value <= 1.0
            return value
          end

          @output.puts "Tem de estar entre 0 (exclusivo) e 1.0."
        rescue ArgumentError
          @output.puts "Valor inválido."
        end
      end
    end
  end
end