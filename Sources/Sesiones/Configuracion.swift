import SwiftUI

// Configuración: el engranaje arriba de la barra lateral (y ⌘, en el menú de la app).
// Cada uno elige lo suyo: el tema y si quiere ver Recientes en la barra lateral (a Rayyan le sirve, a Hugo no).

struct ConfiguracionVista: View {
    @EnvironmentObject var apariencia: Apariencia
    /// Recientes en la barra lateral; prendido por defecto para que nadie lo pierda sin querer
    @AppStorage("verRecientes") private var verRecientes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuración").font(Letra.titulo(15)).foregroundColor(Tema.texto)

            VStack(alignment: .leading, spacing: 9) {
                Text("Tema").font(Letra.fuerte(12)).foregroundColor(Tema.gris)
                ForEach(TemaId.allCases) { t in
                    Button { apariencia.eleccion = t } label: {
                        HStack(spacing: 9) {
                            Image(systemName: apariencia.eleccion == t ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(apariencia.eleccion == t ? Tema.azul : Tema.tenue)
                            Text(t.nombre).font(Letra.texto(13)).foregroundColor(Tema.texto)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle().fill(Tema.linea).frame(height: 1)

            VStack(alignment: .leading, spacing: 9) {
                Text("Barra lateral").font(Letra.fuerte(12)).foregroundColor(Tema.gris)
                Toggle(isOn: $verRecientes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mostrar Recientes").font(Letra.texto(13)).foregroundColor(Tema.texto)
                        Text("Tus últimas 5 sesiones, arriba de las pestañas").font(Letra.texto(11)).foregroundColor(Tema.tenue)
                    }
                }
                .toggleStyle(.switch)
                .tint(Tema.azul)
            }
        }
        .padding(18)
        .frame(width: 310, alignment: .leading)
        .background(Tema.lado)
    }
}

/// El engranaje arriba de la barra lateral: abre la configuración al lado.
struct BotonConfiguracion: View {
    @EnvironmentObject var apariencia: Apariencia
    @State private var abierta = false

    var body: some View {
        Button { abierta.toggle() } label: {
            Image(systemName: "gearshape").font(Letra.fuerte(12.5)).foregroundColor(Tema.gris)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Configuración (⌘,)")
        .popover(isPresented: $abierta, arrowEdge: .bottom) {
            ConfiguracionVista().environmentObject(apariencia)
        }
    }
}
