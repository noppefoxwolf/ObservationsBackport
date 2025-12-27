import ObservationsBackport
import UIKit

class ViewController: UIViewController {
    let label1: UILabel = UILabel()
    let label2: UILabel = UILabel()
    let button1: UIButton = UIButton(configuration: .filled())
    let button2: UIButton = UIButton(configuration: .filled())

    let state = ObservationsState()
    let backportState = ObservationsBackportState()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        label1.text = "Hello, World!"
        label2.text = "Hello, World!"
        button1.configuration?.title = "Increment (Observations)"
        button2.configuration?.title = "Increment (ObservationsBackport)"

        let stackView = UIStackView(
            arrangedSubviews: [
                label1,
                button1,
                label2,
                button2,
            ]
        )
        stackView.axis = .vertical
        view.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.centerYAnchor.constraint(
                equalTo: view.centerYAnchor
            ),
            stackView.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 20
            ),
            view.trailingAnchor.constraint(
                equalTo: stackView.safeAreaLayoutGuide.trailingAnchor,
                constant: 20
            ),
        ])

        button1.addAction(
            UIAction { _ in
                self.state.count += 1
            },
            for: .primaryActionTriggered
        )
        
        button2.addAction(
            UIAction { _ in
                self.backportState.count += 1
            },
            for: .primaryActionTriggered
        )

        Task {
            for await count in Observations({ self.state.count }) {
                let date = Date.now.formatted(date: .omitted, time: .complete)
                print("log", date)
                self.label1.text = "\(count) \(date)"
            }
        }
        
        Task {
            for await count in ObservationsBackport({ self.backportState.count }) {
                let date = Date.now.formatted(date: .omitted, time: .complete)
                print("log", date)
                self.label2.text = "\(count) \(date)"
            }
        }
    }
}

@Observable
final class ObservationsState {
    var count: Int = 0
}

@Observable
final class ObservationsBackportState {
    var count: Int = 0
}
