package hev.htproxy

import androidx.annotation.Keep

/**
 * Declaracao dos metodos nativos do hev-socks5-tunnel.
 *
 * O pacote e o nome desta classe NAO podem mudar. A biblioteca registra os
 * metodos em `JNI_OnLoad` com `RegisterNatives`, procurando exatamente a classe
 * `hev/htproxy/TProxyService` (definida por PKGNAME/CLSNAME em hev-jni.c). Se
 * a classe nao existir com esse nome, o `System.loadLibrary` falha inteiro.
 *
 * As assinaturas tambem sao fixas — hev-jni.c registra:
 *
 *     TProxyStartService  (Ljava/lang/String;I)Z
 *     TProxyStopService   ()Z
 *     TProxyIsRunning     ()Z
 *     TProxyGetStats      ()[J
 *
 * Repare que todas devolvem boolean, nao void.
 *
 * Quem usa isto no app e [br.com.tunnelsystem.app.tunnel.Tun2Socks]; esta
 * classe existe apenas para satisfazer o contrato da biblioteca.
 *
 * O `@Keep` NAO e decorativo. Os builds de release do Flutter rodam R8, que
 * remove metodo nativo sem chamador — e `RegisterNatives` registra os quatro
 * de uma vez: se um sumir, ele devolve erro, `JNI_OnLoad` retorna JNI_ERR e o
 * `System.loadLibrary` inteiro falha. O tunel entao nunca sobe, com uma
 * mensagem que nao aponta para a causa.
 */
@Keep
object TProxyService {

    /**
     * @param configPath caminho do YAML de configuracao
     * @param fd         descritor da interface TUN entregue pela VpnService
     */
    @Keep
    @JvmStatic
    external fun TProxyStartService(configPath: String, fd: Int): Boolean

    @Keep
    @JvmStatic
    external fun TProxyStopService(): Boolean

    @Keep
    @JvmStatic
    external fun TProxyIsRunning(): Boolean

    /** [bytesRecebidos, bytesEnviados] */
    @Keep
    @JvmStatic
    external fun TProxyGetStats(): LongArray
}
