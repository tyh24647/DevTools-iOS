import SwiftUI

struct RulesHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rules Help")
                .font(.largeTitle)
                .bold()
            
            Text("Here are the rules of the game:")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Rule one description goes here.")
                Text("2. Rule two description goes here.")
                Text("3. Rule three description goes here.")
                Text("4. Rule four description goes here.")
                Text("5. Rule five description goes here.")
            }
            .font(.body)
            
            Spacer()
        }
        .padding()
    }
}

struct RulesHelpView_Previews: PreviewProvider {
    static var previews: some View {
        RulesHelpView()
    }
}
